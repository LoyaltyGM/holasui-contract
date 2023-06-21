module holasui::dao {
    use std::string::String;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event::emit;
    use sui::object::{Self, UID, ID};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::table_vec::{Self, TableVec};
    use sui::transfer::share_object;
    use sui::tx_context::{TxContext, sender};
    use sui::vec_map::{Self, VecMap};

    use holasui::staking::AdminCap;

    // ======== Constants =========
    const VERSION: u64 = 1;

    // Vote types
    const VOTE_ABSTAIN: u64 = 0;
    const VOTE_FOR: u64 = 1;
    const VOTE_AGAINST: u64 = 2;

    // Proposal status
    // pending, active, canceled, defeated, executed
    const PROPOSAL_PENDING: u64 = 0;
    const PROPOSAL_ACTIVE: u64 = 1;
    const PROPOSAL_CANCELED: u64 = 2;
    const PROPOSAL_DEFEATED: u64 = 3;
    const PROPOSAL_EXECUTED: u64 = 4;

    // ======== Errors =========
    const EWrongVersion: u64 = 0;
    const ENotUpgrade: u64 = 1;
    const EVotingNotStarted: u64 = 2;
    const EVotingEnded: u64 = 3;
    const EAlreadyVoted: u64 = 4;
    const EWrongVoteType: u64 = 5;

    // ======== Types =========
    struct DAO has drop {}

    struct DaoHub has key {
        id: UID,
        version: u64,
        daos: TableVec<ID>
    }

    struct Dao<phantom T: key + store> has key {
        id: UID,
        version: u64,
        name: String,
        description: String,
        // initial votes for each nft
        // votes_per_nft: u64,
        // minimum number of nfts voted for a proposal to pass
        quorum: u64,
        // delay since proposal is created until voting start in ms
        voting_delay: u64,
        // duration of voting period in ms
        voting_period: u64,
        treasury: Balance<SUI>,
        proposals: Table<ID, Proposal>,

        // TODO: add delegation
    }

    struct Proposal has key, store {
        id: UID,
        name: String,
        description: String,
        type: String,
        status: u64,
        creator: address,
        start_time: u64,
        end_time: u64,
        // for, against, abstain
        results: VecMap<u64, u64>,
        nft_votes: Table<ID, bool>,
        address_votes: Table<address, u64>,
        address_vote_types: Table<address, u64>
    }

    // ======== Events =========

    struct ProposalCreated has copy, drop {
        id: ID,
        name: String,
        creator: address,
    }

    struct Voted has copy, drop {
        dao_id: ID,
        proposal_id: ID,
        voter: address,
        vote: u64
    }

    // ======== Functions =========

    fun init(_: DAO, ctx: &mut TxContext) {
        share_object(DaoHub {
            id: object::new(ctx),
            version: VERSION,
            daos: table_vec::empty(ctx)
        })
    }

    // ======== Admin functions =========

    entry fun migrate_hub(_: &AdminCap, hub: &mut DaoHub) {
        assert!(hub.version < VERSION, ENotUpgrade);

        hub.version = VERSION;
    }

    entry fun migrate_dao<T: key + store>(_: &AdminCap, dao: &mut Dao<T>) {
        assert!(dao.version < VERSION, ENotUpgrade);

        dao.version = VERSION;
    }

    entry fun create_dao<T: key + store>(
        _: &AdminCap,
        hub: &mut DaoHub,
        name: String,
        description: String,
        // votes_per_nft: u64,
        quorum: u64,
        voting_delay: u64,
        voting_period: u64,
        ctx: &mut TxContext
    ) {
        check_hub_version(hub);

        let dao = Dao<T> {
            id: object::new(ctx),
            version: VERSION,
            name,
            description,
            // votes_per_nft,
            quorum,
            voting_delay,
            voting_period,
            treasury: balance::zero(),
            proposals: table::new(ctx)
        };

        share_object(dao);
    }

    // ======== User functions =========


    public fun create_proposal<T: key + store>(
        dao: &mut Dao<T>,
        _: &T,
        name: String,
        description: String,
        type: String,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        check_dao_version(dao);

        let results = vec_map::empty<u64, u64>();

        vec_map::insert(&mut results, VOTE_FOR, 0);
        vec_map::insert(&mut results, VOTE_AGAINST, 0);
        vec_map::insert(&mut results, VOTE_ABSTAIN, 0);

        let proposal = Proposal {
            id: object::new(ctx),
            name,
            description,
            type,
            status: PROPOSAL_PENDING,
            creator: sender(ctx),
            start_time: clock::timestamp_ms(clock) + dao.voting_delay,
            end_time: clock::timestamp_ms(clock) + dao.voting_delay + dao.voting_period,
            // for, against, abstain
            results,
            nft_votes: table::new(ctx),
            address_votes: table::new(ctx),
            address_vote_types: table::new(ctx)
        };

        emit(ProposalCreated {
            id: object::id(&proposal),
            name: proposal.name,
            creator: proposal.creator
        });

        table::add(&mut dao.proposals, object::id(&proposal), proposal);
    }

    public fun vote<T: key + store>(
        dao: &mut Dao<T>,
        nft: &T,
        proposal_id: ID,
        vote: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        check_dao_version(dao);

        let nft_id = object::id(nft);
        let proposal = table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(clock::timestamp_ms(clock) >= proposal.start_time, EVotingNotStarted);
        assert!(clock::timestamp_ms(clock) <= proposal.end_time, EVotingEnded);
        assert!(!table::contains(&proposal.nft_votes, nft_id), EAlreadyVoted);
        assert!(vote == VOTE_FOR || vote == VOTE_AGAINST || vote == VOTE_ABSTAIN, EWrongVoteType);
        if (table::contains(&proposal.address_vote_types, sender(ctx))) {
            assert!(*table::borrow(&proposal.address_vote_types, sender(ctx)) == vote, EWrongVoteType);
        };

        emit(Voted {
            dao_id: object::uid_to_inner(&dao.id),
            proposal_id,
            voter: sender(ctx),
            vote
        });

        // change status to active if it's pending. called only once
        if (proposal.status == PROPOSAL_PENDING) {
            proposal.status = PROPOSAL_ACTIVE;
        };

        // update results with selected vote type
        let current_votes = vec_map::get_mut(&mut proposal.results, &vote) ;
        *current_votes = *current_votes + 1;

        // add nft to voted nfts to prevent double voting with same nft
        table::add(&mut proposal.nft_votes, nft_id, true);

        // count address votes. if address already voted, just increment vote count
        if (table::contains(&proposal.address_votes, sender(ctx))) {
            let current_address_vote = table::borrow_mut(&mut proposal.address_votes, sender(ctx));
            *current_address_vote = *current_address_vote + 1;
        } else {
            table::add(&mut proposal.address_votes, sender(ctx), 1);
        };

        // add address to address_vote_types to prevent voting with different vote type
        if (!table::contains(&proposal.address_vote_types, sender(ctx))) {
            table::add(&mut proposal.address_vote_types, sender(ctx), vote);
        };
    }

    // ======== Utility functions =========

    fun check_hub_version(hub: &DaoHub) {
        assert!(hub.version == VERSION, EWrongVersion);
    }

    fun check_dao_version<T: key + store>(dao: &Dao<T>) {
        assert!(dao.version == VERSION, EWrongVersion);
    }
}
