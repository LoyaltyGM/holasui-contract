module holasui::dao {
    use std::option::{Self, Option};
    use std::string::{Self, String};

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin;
    use sui::coin::Coin;
    use sui::event::emit;
    use sui::object::{Self, ID, UID};
    use sui::object_table;
    use sui::object_table::ObjectTable;
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::table_vec::{Self, TableVec};
    use sui::transfer::{public_transfer, share_object};
    use sui::tx_context::{sender, TxContext};
    use sui::url::{Self, Url};
    use sui::vec_map::{Self, VecMap};

    // ======== Constants =========

    // Vote types
    const VOTE_TYPE_ABSTAIN: u64 = 0;
    const VOTE_TYPE_FOR: u64 = 1;
    const VOTE_TYPE_AGAINST: u64 = 2;

    // Proposal types
    const PROPOSAL_TYPE_VOTING: u64 = 0;
    const PROPOSAL_TYPE_FUNDING: u64 = 1;

    // Proposal status
    const PROPOSAL_STATUS_ACTIVE: u64 = 0;
    const PROPOSAL_STATUS_CANCELED: u64 = 1;
    const PROPOSAL_STATUS_DEFEATED: u64 = 2;
    const PROPOSAL_STATUS_EXECUTED: u64 = 3;

    // ======== Errors =========
    const EVotingNotStarted: u64 = 0;
    const EVotingEnded: u64 = 1;
    const EVotingStarted: u64 = 2;
    const EVotingNotEnded: u64 = 3;
    const EAlreadyVoted: u64 = 4;
    const EWrongVoteType: u64 = 5;
    const ENotProposalCreator: u64 = 6;
    const EProposalNotActive: u64 = 7;
    const EWrongProposalType: u64 = 8;

    // ======== Types =========
    struct DAO has drop {}

    struct DaoHub has key {
        id: UID,
        daos: TableVec<ID>
    }

    struct Dao<phantom T: key + store> has key {
        id: UID,
        name: String,
        description: String,
        image: Url,
        // minimum number of nfts voted for a proposal to pass
        quorum: u64,
        // delay since proposal is created until voting start in ms
        voting_delay: u64,
        // duration of voting period in ms
        voting_period: u64,
        treasury: Balance<SUI>,
        proposals: ObjectTable<ID, Proposal>,
        subdaos: TableVec<ID>
    }

    struct Proposal has key, store {
        id: UID,
        name: String,
        description: String,
        type: u64,
        recipient: Option<address>,
        amount: Option<u64>,
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

    struct ProposalCanceled has copy, drop {
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

    struct ProposalEnded has copy, drop {
        id: ID,
        status: u64,
        name: String,
    }


    // ======== Functions =========

    fun init(_: DAO, ctx: &mut TxContext) {
        share_object(DaoHub {
            id: object::new(ctx),
            daos: table_vec::empty(ctx)
        })
    }

    // ======== User functions =========

    entry fun create_dao<T: key + store>(
        hub: &mut DaoHub,
        _: &T,
        name: String,
        description: String,
        image: String,
        quorum: u64,
        voting_delay: u64,
        voting_period: u64,
        ctx: &mut TxContext
    ) {
        let dao = Dao<T> {
            id: object::new(ctx),
            name,
            description,
            image: url::new_unsafe(string::to_ascii(image)),
            quorum,
            voting_delay,
            voting_period,
            treasury: balance::zero(),
            proposals: object_table::new(ctx),
            subdaos: table_vec::empty(ctx),
        };

        table_vec::push_back(&mut hub.daos, object::id(&dao));
        share_object(dao);
    }

    public fun create_proposal<T: key + store>(
        dao: &mut Dao<T>,
        _: &T,
        name: String,
        description: String,
        type: u64,
        recipient: Option<address>,
        amount: Option<u64>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(type == PROPOSAL_TYPE_VOTING || type == PROPOSAL_TYPE_FUNDING, EWrongProposalType);

        if (type == PROPOSAL_TYPE_FUNDING) {
            assert!(option::is_some(&recipient), EWrongProposalType);
            assert!(option::is_some(&amount), EWrongProposalType);
        }
        else if (type == PROPOSAL_TYPE_VOTING) {
            assert!(option::is_none(&recipient), EWrongProposalType);
            assert!(option::is_none(&amount), EWrongProposalType);
        };


        let results = vec_map::empty<u64, u64>();

        vec_map::insert(&mut results, VOTE_TYPE_FOR, 0);
        vec_map::insert(&mut results, VOTE_TYPE_AGAINST, 0);
        vec_map::insert(&mut results, VOTE_TYPE_ABSTAIN, 0);

        let proposal = Proposal {
            id: object::new(ctx),
            name,
            description,
            type,
            recipient,
            amount,
            status: PROPOSAL_STATUS_ACTIVE,
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

        object_table::add(&mut dao.proposals, object::id(&proposal), proposal);
    }

    entry fun cancel_proposal<T: key + store>(
        dao: &mut Dao<T>,
        proposal_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let proposal = object_table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(proposal.creator == sender(ctx), ENotProposalCreator);
        assert!(proposal.status == PROPOSAL_STATUS_ACTIVE, EProposalNotActive);
        assert!(clock::timestamp_ms(clock) < proposal.start_time, EVotingStarted);

        proposal.status = PROPOSAL_STATUS_CANCELED;
    }

    entry fun vote<T: key + store>(
        dao: &mut Dao<T>,
        nft: &T,
        proposal_id: ID,
        vote: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let nft_id = object::id(nft);
        let proposal = object_table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(proposal.status == PROPOSAL_STATUS_ACTIVE, EProposalNotActive);
        assert!(clock::timestamp_ms(clock) >= proposal.start_time, EVotingNotStarted);
        assert!(clock::timestamp_ms(clock) <= proposal.end_time, EVotingEnded);
        assert!(!table::contains(&proposal.nft_votes, nft_id), EAlreadyVoted);
        assert!(vote == VOTE_TYPE_FOR || vote == VOTE_TYPE_AGAINST || vote == VOTE_TYPE_ABSTAIN, EWrongVoteType);
        if (table::contains(&proposal.address_vote_types, sender(ctx))) {
            assert!(*table::borrow(&proposal.address_vote_types, sender(ctx)) == vote, EWrongVoteType);
        };

        emit(Voted {
            dao_id: object::uid_to_inner(&dao.id),
            proposal_id,
            voter: sender(ctx),
            vote
        });

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

    entry fun execute_proposal<T: key + store>(
        dao: &mut Dao<T>,
        proposal_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let proposal = object_table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(proposal.status == PROPOSAL_STATUS_ACTIVE, EProposalNotActive);
        assert!(clock::timestamp_ms(clock) >= proposal.end_time, EVotingNotEnded);

        let results = proposal.results;
        let votes_for = *vec_map::get(&results, &VOTE_TYPE_FOR);
        let votes_against = *vec_map::get(&results, &VOTE_TYPE_AGAINST);
        let votes_abstain = *vec_map::get(&results, &VOTE_TYPE_ABSTAIN);
        let total_votes = votes_for + votes_against + votes_abstain;


        proposal.status =
            if (total_votes < dao.quorum) PROPOSAL_STATUS_DEFEATED
            else {
                if (votes_for > votes_against) PROPOSAL_STATUS_EXECUTED
                else PROPOSAL_STATUS_DEFEATED
            };

        emit(ProposalEnded {
            id: proposal_id,
            name: proposal.name,
            status: proposal.status,
        });

        if (proposal.status == PROPOSAL_STATUS_EXECUTED && proposal.type == PROPOSAL_TYPE_FUNDING) {
            let recipient = *option::borrow(&proposal.recipient);
            let amount = *option::borrow(&proposal.amount);

            public_transfer(coin::take(&mut dao.treasury, amount, ctx), recipient);
        }
    }

    entry fun deposit_to_treasury<T: key + store>(
        dao: &mut Dao<T>,
        coin: Coin<SUI>,
    ) {
        coin::put(&mut dao.treasury, coin);
    }

    // ======== Friend functions =========

    public(friend) fun update_subdaos<T: key + store>(
        dao: &mut Dao<T>,
        subdao: ID,
    ) {
        table_vec::push_back(&mut dao.subdaos, subdao);
    }


    // ======== Utility functions =========
}
