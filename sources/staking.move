module holasui::staking {
    use std::string::{Self, String, utf8};

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::display;
    use sui::dynamic_object_field as dof;
    use sui::event::emit;
    use sui::math::min;
    use sui::object::{Self, UID, ID};
    use sui::package;
    use sui::pay;
    use sui::sui::SUI;
    use sui::table_vec::{Self, TableVec};
    use sui::transfer::{public_transfer, share_object, transfer};
    use sui::tx_context::{TxContext, sender};
    use sui::url::{Self, Url};

    use holasui::holasui::{AdminCap, version, project_url};
    use holasui::utils::{withdraw_balance, handle_payment};

    // ======== Constants =========
    const FEE_FOR_STAKE: u64 = 1000000000;
    const FEE_FOR_UNSTAKE: u64 = 3000000000;
    const FEE_FOR_CLAIM: u64 = 1000000000;
    const POINTS_PER_DAY: u64 = 100;

    const TICKET_NAME: vector<u8> = b"Staking Ticket";
    const TICKET_IMAGE_URL: vector<u8> = b"ipfs://QmQiqGdJJb16QHaLPXDY6VZGqiDpehaSviU6vZQSvKdhNd";

    // ======== Errors =========

    const EStakingEnded: u64 = 0;
    const EWrongVersion: u64 = 1;
    const ENotUpgrade: u64 = 2;

    // ======== Types =========

    struct STAKING has drop {}

    // Only one instance of this struct is created
    struct StakingHub has key {
        id: UID,
        version: u64,
        balance: Balance<SUI>,
        pools: TableVec<ID>,
    }

    // Creatable by admin
    struct StakingPool<phantom NFT, phantom COIN> has key {
        id: UID,
        version: u64,
        name: String,
        /// End time of staking in milliseconds
        end_time: u64,
        fee_for_stake: u64,
        fee_for_unstake: u64,
        fee_for_claim: u64,
        rewards_per_day: u64,
        /// Total staked nfts per current pool
        staked: u64,
        rewards_balance: Balance<COIN>,
    }

    struct StakingTicket has key {
        id: UID,
        name: String,
        image_url: Url,

        nft_id: ID,
        start_time: u64,
    }

    // ======== Events =========

    struct Staked has copy, drop {
        nft_id: ID,
    }

    struct Unstaked has copy, drop {
        nft_id: ID,
        rewards: u64,
    }

    struct Claimed has copy, drop {
        nft_id: ID,
        rewards: u64,
    }

    // ======== Functions =========

    fun init(otw: STAKING, ctx: &mut TxContext) {
        // Publisher
        let publisher = package::claim(otw, ctx);

        // Ticket display
        let ticket_keys = vector[
            utf8(b"name"),
            utf8(b"image_url"),
            utf8(b"project_url"),
        ];
        let ticket_values = vector[
            utf8(b"{name}"),
            utf8(b"{image_url}"),
            project_url()
        ];
        let ticket_display = display::new_with_fields<StakingTicket>(
            &publisher, ticket_keys, ticket_values, ctx
        );
        display::update_version(&mut ticket_display);

        // Staking hub
        let hub = StakingHub {
            id: object::new(ctx),
            version: version(),
            balance: balance::zero(),
            pools: table_vec::empty<ID>(ctx),
        };

        public_transfer(publisher, sender(ctx));
        public_transfer(ticket_display, sender(ctx));
        share_object(hub);
    }

    // ======== Admin functions =========

    entry fun withdraw_hub(_: &AdminCap, hub: &mut StakingHub, ctx: &mut TxContext) {
        check_hub_version(hub);

        withdraw_balance(&mut hub.balance, ctx);
    }

    /// not only admin can call this function
    entry fun deposit_pool<NFT, COIN>(pool: &mut StakingPool<NFT, COIN>, coin: Coin<COIN>) {
        check_pool_version(pool);

        coin::put(&mut pool.rewards_balance, coin);
    }

    entry fun withdraw_pool<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, ctx: &mut TxContext) {
        check_pool_version(pool);

        withdraw_balance(&mut pool.rewards_balance, ctx);
    }

    entry fun create_pool<NFT, COIN>(_: &AdminCap, hub: &mut StakingHub, name: String, ctx: &mut TxContext) {
        check_hub_version(hub);

        let pool = StakingPool<NFT, COIN> {
            id: object::new(ctx),
            version: version(),
            name,
            end_time: 0,
            fee_for_stake: FEE_FOR_STAKE,
            fee_for_unstake: FEE_FOR_UNSTAKE,
            fee_for_claim: FEE_FOR_CLAIM,
            rewards_per_day: POINTS_PER_DAY,
            staked: 0,
            rewards_balance: balance::zero<COIN>(),
        };

        // Add poolId to list of pools
        table_vec::push_back(&mut hub.pools, object::id(&pool));

        share_object(pool);
    }

    entry fun set_name<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, name: String) {
        check_pool_version(pool);

        pool.name = name;
    }

    entry fun update_end_time<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, end_time: u64) {
        check_pool_version(pool);

        pool.end_time = end_time;
    }

    entry fun set_fee_for_stake<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, fee: u64) {
        check_pool_version(pool);

        pool.fee_for_stake = fee;
    }

    entry fun set_fee_for_unstake<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, fee: u64) {
        check_pool_version(pool);

        pool.fee_for_unstake = fee;
    }

    entry fun set_fee_for_claim<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, fee: u64) {
        check_pool_version(pool);

        pool.fee_for_claim = fee;
    }

    entry fun set_rewards_per_day<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, rewards: u64) {
        check_pool_version(pool);

        pool.rewards_per_day = rewards;
    }

    entry fun migrate_hub(_: &AdminCap, hub: &mut StakingHub) {
        assert!(hub.version < version(), ENotUpgrade);

        hub.version = version();
    }

    entry fun migrate_pool<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>) {
        assert!(pool.version < version(), ENotUpgrade);

        pool.version = version();
    }

    // ======== User functions =========

    //todo: add hola points for stake
    entry fun stake<NFT: key + store, COIN>(
        nft: NFT,
        hub: &mut StakingHub,
        pool: &mut StakingPool<NFT, COIN>,
        coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        check_hub_version(hub);
        check_pool_version(pool);

        assert!(clock::timestamp_ms(clock) < pool.end_time, EStakingEnded);
        handle_payment(&mut hub.balance, coin, pool.fee_for_stake, ctx);

        let nft_id: ID = object::id(&nft);

        let name = pool.name;
        string::append_utf8(&mut name, b" ");
        string::append_utf8(&mut name, b"Staking Ticket");

        let ticket = StakingTicket {
            id: object::new(ctx),
            name,
            image_url: url::new_unsafe_from_bytes(TICKET_IMAGE_URL),
            nft_id,
            start_time: clock::timestamp_ms(clock)
        };

        pool.staked = pool.staked + 1;

        emit(Staked {
            nft_id,
        });

        dof::add<ID, NFT>(&mut pool.id, nft_id, nft);
        transfer(ticket, sender(ctx));
    }

    entry fun unstake<NFT: key + store, COIN>(
        ticket: StakingTicket,
        hub: &mut StakingHub,
        pool: &mut StakingPool<NFT, COIN>,
        coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        check_hub_version(hub);
        check_pool_version(pool);

        handle_payment(&mut hub.balance, coin, pool.fee_for_unstake, ctx);

        let rewards = calculate_rewards(pool, &ticket, clock);

        let sender_rewards_coin = coin::take(
            &mut pool.rewards_balance,
            rewards,
            ctx
        );

        let StakingTicket { id, nft_id, start_time: _, name: _, image_url: _, } = ticket;

        let nft = dof::remove<ID, NFT>(&mut pool.id, nft_id);

        pool.staked = if (pool.staked > 0) pool.staked - 1 else 0 ;

        emit(Unstaked {
            nft_id,
            rewards,
        });

        object::delete(id);
        public_transfer(nft, sender(ctx));
        pay::keep(sender_rewards_coin, ctx);
    }

    entry fun claim<NFT: key + store, COIN>(
        ticket: &mut StakingTicket,
        hub: &mut StakingHub,
        pool: &mut StakingPool<NFT, COIN>,
        coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        check_hub_version(hub);
        check_pool_version(pool);

        handle_payment(&mut hub.balance, coin, pool.fee_for_claim, ctx);

        let rewards = calculate_rewards(pool, ticket, clock);

        let sender_rewards_coin = coin::take(
            &mut pool.rewards_balance,
            rewards,
            ctx
        );

        emit(Claimed {
            nft_id: ticket.nft_id,
            rewards,
        });

        ticket.start_time = clock::timestamp_ms(clock);
        pay::keep(sender_rewards_coin, ctx);
    }


    // ======== View functions =========

    // ======== Utility functions =========

    fun calculate_rewards<NFT, COIN>(pool: &StakingPool<NFT, COIN>, ticket: &StakingTicket, clock: &Clock): u64 {
        (min(pool.end_time,clock::timestamp_ms(clock)) - ticket.start_time) / 1000 / 60 / 60 / 24 * pool.rewards_per_day
    }

    fun check_hub_version(hub: &StakingHub) {
        assert!(hub.version == version(), EWrongVersion);
    }

    fun check_pool_version<NFT, COIN>(pool: &StakingPool<NFT, COIN>) {
        assert!(pool.version == version(), EWrongVersion);
    }
}