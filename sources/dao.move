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

    // Voting types
    const VOTE_ABSTAIN: u64 = 0;
    const VOTE_FOR: u64 = 1;
    const VOTE_AGAINST: u64 = 2;

    // ======== Errors =========
    const EWrongVersion: u64 = 0;
    const ENotUpgrade: u64 = 1;
    const EVotingNotStarted: u64 = 2;
    const EVotingEnded: u64 = 3;

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
        initial_votes: u64,
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
        creator: address,
        start_time: u64,
        end_time: u64,
        // for, against, abstain
        results: VecMap<u64, u64>,
        nft_votes: Table<ID, u64>,
        address_votes: Table<address, u64>
    }

    // ======== Events =========

    struct ProposalCreated has copy, drop {
        id: ID,
        name: String,
        creator: address,
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
        initial_votes: u64,
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
            initial_votes,
            quorum,
            voting_delay,
            voting_period,
            treasury: balance::zero(),
            proposals: table::new(ctx)
        };

        share_object(dao);
    }

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
            creator: sender(ctx),
            start_time: clock::timestamp_ms(clock) + dao.voting_delay,
            end_time: clock::timestamp_ms(clock) + dao.voting_delay + dao.voting_period,
            // for, against, abstain
            results,
            nft_votes: table::new(ctx),
            address_votes: table::new(ctx)
        };

        emit(ProposalCreated {
            id: object::id(&proposal),
            name: proposal.name,
            creator: proposal.creator
        });

        table::add(&mut dao.proposals, object::id(&proposal), proposal);
    }

    // ======== User functions =========


    // ======== Utility functions =========

    fun check_hub_version(hub: &DaoHub) {
        assert!(hub.version == VERSION, EWrongVersion);
    }

    fun check_dao_version<T: key + store>(dao: &Dao<T>) {
        assert!(dao.version == VERSION, EWrongVersion);
    }
}
