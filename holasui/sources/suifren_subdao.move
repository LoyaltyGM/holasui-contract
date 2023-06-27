/*
    Example of creating a DAO by attribute of a NFT
    In this example, a DAO can be created by a SuiFren birth location attribute
    So only SuiFrens with the same birth location can participate in the DAO
*/

module holasui::suifren_subdao {
    use std::string;
    use std::string::String;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event::emit;
    use sui::object::{Self, ID, UID};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::transfer::share_object;
    use sui::tx_context::{sender, TxContext};
    use sui::url;
    use sui::url::Url;
    use sui::vec_map::{Self, VecMap};
    use suifrens::suifrens::{Self, SuiFren};

    use holasui::staking::AdminCap;
    use holasui::suifren_dao;
    use holasui::suifren_dao::Dao;

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
    const EVotingNotStarted: u64 = 0;
    const EVotingEnded: u64 = 1;
    const EVotingStarted: u64 = 2;
    const EVotingNotEnded: u64 = 3;
    const EAlreadyVoted: u64 = 4;
    const EWrongVoteType: u64 = 5;
    const ENotProposalCreator: u64 = 6;
    const EProposalNotActive: u64 = 7;
    const EWrongBirthLocation: u64 = 8;

    // ======== Types =========
    struct SUIFREN_SUBDAO has drop {}

    struct SubDao<phantom T: key + store> has key {
        id: UID,
        origin_dao: ID,
        birth_location: String,
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

    // ======== Admin functions =========

    entry fun create_subdao<T: key + store>(
        _: &AdminCap,
        dao: &mut Dao<T>,
        birth_location: String,
        name: String,
        description: String,
        image: String,
        quorum: u64,
        voting_delay: u64,
        voting_period: u64,
        ctx: &mut TxContext
    ) {
        let subdao = SubDao<T> {
            id: object::new(ctx),
            origin_dao: object::id(dao),
            birth_location,
            name,
            description,
            image: url::new_unsafe(string::to_ascii(image)),
            quorum,
            voting_delay,
            voting_period,
            treasury: balance::zero(),
            proposals: table::new(ctx)
        };

        suifren_dao::update_subdaos(dao, object::id(&subdao));
        share_object(subdao);
    }

    // ======== User functions =========


    entry fun create_proposal<T: key + store>(
        dao: &mut SubDao<T>,
        fren: &SuiFren<T>,
        name: String,
        description: String,
        type: String,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(dao.birth_location == suifrens::birth_location(fren), EWrongBirthLocation);

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
        dao: &mut SubDao<T>,
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
        dao: &mut SubDao<T>,
        fren: &SuiFren<T>,
        proposal_id: ID,
        vote: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(dao.birth_location == suifrens::birth_location(fren), EWrongBirthLocation);

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
        dao: &mut SubDao<T>,
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

    // ======== Utility functions =========
}
