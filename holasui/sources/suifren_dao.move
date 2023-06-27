module holasui::suifren_dao {
    use std::string;
    use std::string::String;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event::emit;
    use sui::object::{Self, ID, UID};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::table_vec::{Self, TableVec};
    use sui::transfer::share_object;
    use sui::tx_context::{sender, TxContext};
    use sui::url;
    use sui::url::Url;
    use sui::vec_map::{Self, VecMap};
    use suifrens::suifrens::SuiFren;

    use holasui::staking::AdminCap;

    friend holasui::suifren_subdao;
    // ======== Constants =========

    // Vote types
    const VOTE_ABSTAIN: u64 = 0;
    const VOTE_FOR: u64 = 1;
    const VOTE_AGAINST: u64 = 2;

    // Proposal status
    const PROPOSAL_ACTIVE: u64 = 0;
    const PROPOSAL_CANCELED: u64 = 1;
    const PROPOSAL_DEFEATED: u64 = 2;
    const PROPOSAL_EXECUTED: u64 = 3;

    // ======== Errors =========
    const EVotingNotStarted: u64 = 2;
    const EVotingEnded: u64 = 3;
    const EVotingStarted: u64 = 4;
    const EVotingNotEnded: u64 = 5;
    const EAlreadyVoted: u64 = 6;
    const EWrongVoteType: u64 = 7;
    const ENotProposalCreator: u64 = 8;
    const EProposalNotActive: u64 = 9;
    const EWrongBirthLocation: u64 = 10;

    // ======== Types =========
    struct SUIFREN_DAO has drop {}

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
        proposals: Table<ID, Proposal>,
        subdaos: TableVec<ID>
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

    struct ProposalExecuted has copy, drop {
        id: ID,
        name: String,
    }

    struct ProposalDefeated has copy, drop {
        id: ID,
        name: String,
    }


    // ======== Functions =========

    fun init(_: SUIFREN_DAO, ctx: &mut TxContext) {
        share_object(DaoHub {
            id: object::new(ctx),
            daos: table_vec::empty(ctx)
        })
    }

    // ======== Admin functions =========

    entry fun create_dao<T: key + store>(
        _: &AdminCap,
        hub: &mut DaoHub,
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
            // votes_per_nft,
            quorum,
            voting_delay,
            voting_period,
            treasury: balance::zero(),
            proposals: table::new(ctx),
            subdaos: table_vec::empty(ctx),
        };

        table_vec::push_back(&mut hub.daos, object::id(&dao));
        share_object(dao);
    }

    // ======== User functions =========


    entry fun create_proposal<T: key + store>(
        dao: &mut Dao<T>,
        _: &SuiFren<T>,
        name: String,
        description: String,
        type: String,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let results = vec_map::empty<u64, u64>();

        vec_map::insert(&mut results, VOTE_FOR, 0);
        vec_map::insert(&mut results, VOTE_AGAINST, 0);
        vec_map::insert(&mut results, VOTE_ABSTAIN, 0);

        let proposal = Proposal {
            id: object::new(ctx),
            name,
            description,
            type,
            status: PROPOSAL_ACTIVE,
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

    entry fun cancel_proposal<T: key + store>(
        dao: &mut Dao<T>,
        proposal_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let proposal = table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(proposal.creator == sender(ctx), ENotProposalCreator);
        assert!(proposal.status == PROPOSAL_ACTIVE, EProposalNotActive);
        assert!(clock::timestamp_ms(clock) < proposal.start_time, EVotingStarted);

        proposal.status = PROPOSAL_CANCELED;
    }

    entry fun vote<T: key + store>(
        dao: &mut Dao<T>,
        fren: &SuiFren<T>,
        proposal_id: ID,
        vote: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let nft_id = object::id(fren);
        let proposal = table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(proposal.status == PROPOSAL_ACTIVE, EProposalNotActive);
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
    ) {
        let proposal = table::borrow_mut(&mut dao.proposals, proposal_id);
        assert!(proposal.status == PROPOSAL_ACTIVE, EProposalNotActive);
        assert!(clock::timestamp_ms(clock) >= proposal.end_time, EVotingNotEnded);

        let results = proposal.results;
        let votes_for = *vec_map::get(&results, &VOTE_FOR);
        let votes_against = *vec_map::get(&results, &VOTE_AGAINST);
        let votes_abstain = *vec_map::get(&results, &VOTE_ABSTAIN);
        let total_votes = votes_for + votes_against + votes_abstain;


        if (total_votes < dao.quorum) {
            proposal.status = PROPOSAL_DEFEATED;
            emit(ProposalDefeated {
                id: proposal_id,
                name: proposal.name
            });
        } else {
            if (votes_for > votes_against) {
                proposal.status = PROPOSAL_EXECUTED;
                emit(ProposalExecuted {
                    id: proposal_id,
                    name: proposal.name
                });
            } else {
                proposal.status = PROPOSAL_DEFEATED;
                emit(ProposalDefeated {
                    id: proposal_id,
                    name: proposal.name
                });
            }
        };
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
