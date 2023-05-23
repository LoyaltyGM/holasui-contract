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
    use sui::table::{Self, Table};
    use sui::transfer::{public_transfer, share_object, transfer};
    use sui::tx_context::{TxContext, sender};
    use sui::url::{Self, Url};

    // ======== Constants =========
    // initial values
    const VERSION: u64 = 1;
    const FEE_FOR_STAKE: u64 = 1000000000;
    const FEE_FOR_UNSTAKE: u64 = 3000000000;
    const FEE_FOR_CLAIM: u64 = 1000000000;
    const POINTS_PER_DAY: u64 = 100;

    const TICKET_NAME: vector<u8> = b"Staking Ticket";
    const TICKET_IMAGE_URL: vector<u8> = b"ipfs://QmQiqGdJJb16QHaLPXDY6VZGqiDpehaSviU6vZQSvKdhNd";

    // ======== Errors =========

    const EInsufficientPay: u64 = 0;
    const EZeroBalance: u64 = 1;
    const EInsufficientRewards: u64 = 2;
    const EStakingEnded: u64 = 3;
    const EWrongVersion: u64 = 4;
    const ENotUpgrade: u64 = 5;

    // ======== Types =========

    struct STAKING has drop {}

    struct AdminCap has key, store {
        id: UID,
    }

    // Only one instance of this struct is created
    struct StakingHub has key {
        id: UID,
        version: u64,
        balance: Balance<SUI>,
        /// Total staked nfts per all pools
        staked: u64,

        // dof

        // Pools
        // pools: Table<ID, bool>,

        // Rewards from each pool
        // rewards: Table<address, u64>, // total rewards from all pools
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

        // dof

        // Rewards for current pool
        // rewards: Table<address, u64>,
    }

    struct StakingTicket has key {
        id: UID,
        name: String,
        url: Url,

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
            utf8(b"{url}"),
            utf8(b"https://www.holasui.xyz"),
        ];
        let ticket_display = display::new_with_fields<StakingTicket>(
            &publisher, ticket_keys, ticket_values, ctx
        );
        display::update_version(&mut ticket_display);

        // Staking hub
        let hub = StakingHub {
            id: object::new(ctx),
            version: VERSION,
            balance: balance::zero(),
            staked: 0,
        };
        dof::add<String, Table<address, u64>>(&mut hub.id, rewards_key(), table::new<address, u64>(ctx));
        dof::add<String, Table<ID, bool>>(&mut hub.id, pools_key(), table::new<ID, bool>(ctx));

        public_transfer(publisher, sender(ctx));
        public_transfer(ticket_display, sender(ctx));
        public_transfer(AdminCap {
            id: object::new(ctx),
        }, sender(ctx));
        share_object(hub);
    }

    // ======== Admin functions =========

    entry fun withdraw_hub(_: &AdminCap, hub: &mut StakingHub, ctx: &mut TxContext) {
        check_hub_version(hub);

        let amount = balance::value(&hub.balance);
        assert!(amount > 0, EZeroBalance);

        pay::keep(coin::take(&mut hub.balance, amount, ctx), ctx);
    }

    /// not only admin can call this function
    entry fun deposit_pool<NFT, COIN>(pool: &mut StakingPool<NFT, COIN>, coin: Coin<COIN>) {
        check_pool_version(pool);

        coin::put(&mut pool.rewards_balance, coin);
    }

    entry fun withdraw_pool<NFT, COIN>(_: &AdminCap, pool: &mut StakingPool<NFT, COIN>, ctx: &mut TxContext) {
        check_pool_version(pool);

        let amount = balance::value(&pool.rewards_balance);
        assert!(amount > 0, EZeroBalance);

        pay::keep(coin::take(&mut pool.rewards_balance, amount, ctx), ctx);
    }

    entry fun create_pool<NFT, COIN>(_: &AdminCap, hub: &mut StakingHub, name: String, ctx: &mut TxContext) {
        check_hub_version(hub);

        let pool = StakingPool<NFT, COIN> {
            id: object::new(ctx),
            version: VERSION,
            name,
            end_time: 0,
            fee_for_stake: FEE_FOR_STAKE,
            fee_for_unstake: FEE_FOR_UNSTAKE,
            fee_for_claim: FEE_FOR_CLAIM,
            rewards_per_day: POINTS_PER_DAY,
            staked: 0,
            rewards_balance: balance::zero<COIN>(),
        };
        dof::add<String, Table<address, u64>>(&mut pool.id, rewards_key(), table::new<address, u64>(ctx));

        // Add poolId to list of pools
        table::add(borrow_hub_pools_mut(hub), object::id(&pool), true);

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

    entry fun migrate_hub(_: AdminCap, hub: &mut StakingHub) {
        assert!(hub.version < VERSION, ENotUpgrade);

        hub.version = VERSION;
    }

    entry fun migrate_pool<NFT, COIN>(_: AdminCap, pool: &mut StakingPool<NFT, COIN>) {
        assert!(pool.version < VERSION, ENotUpgrade);

        pool.version = VERSION;
    }

    // ======== User functions =========

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
        handle_payment(hub, coin, pool.fee_for_stake, ctx);

        let nft_id: ID = object::id(&nft);

        let name = pool.name;
        string::append_utf8(&mut name, b" ");
        string::append_utf8(&mut name, b"Staking Ticket");

        let ticket = StakingTicket {
            id: object::new(ctx),
            name,
            url: url::new_unsafe_from_bytes(TICKET_IMAGE_URL),
            nft_id,
            start_time: clock::timestamp_ms(clock)
        };

        hub.staked = hub.staked + 1;
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

        handle_payment(hub, coin, pool.fee_for_unstake, ctx);

        let rewards = calculate_rewards(pool, &ticket, clock);
        add_rewards(borrow_hub_rewards_mut(hub), sender(ctx), rewards);
        add_rewards(borrow_pool_rewards_mut(pool), sender(ctx), rewards);

        let sender_rewards = remove_rewards(borrow_pool_rewards_mut(pool), sender(ctx));
        let sender_rewards_coin = coin::take(
            &mut pool.rewards_balance,
            sender_rewards,
            ctx
        );

        let StakingTicket { id, nft_id, start_time: _, name: _, url: _, } = ticket;

        let nft = dof::remove<ID, NFT>(&mut pool.id, nft_id);

        hub.staked = if (hub.staked > 0) hub.staked - 1 else 0 ;
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

        handle_payment(hub, coin, pool.fee_for_claim, ctx);

        let rewards = calculate_rewards(pool, ticket, clock);
        add_rewards(borrow_hub_rewards_mut(hub), sender(ctx), rewards);
        add_rewards(borrow_pool_rewards_mut(pool), sender(ctx), rewards);

        let sender_rewards = remove_rewards(borrow_pool_rewards_mut(pool), sender(ctx));
        let sender_rewards_coin = coin::take(
            &mut pool.rewards_balance,
            sender_rewards,
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

    fun rewards_key(): String {
        utf8(b"rewards")
    }

    fun pools_key(): String {
        utf8(b"pools")
    }

    fun handle_payment(hub: &mut StakingHub, coin: Coin<SUI>, price: u64, ctx: &mut TxContext) {
        assert!(coin::value(&coin) >= price, EInsufficientPay);

        let payment = coin::split(&mut coin, price, ctx);

        coin::put(&mut hub.balance, payment);
        pay::keep(coin, ctx);
    }

    fun add_rewards(table: &mut Table<address, u64>, address: address, rewards_to_add: u64) {
        if (rewards_to_add == 0) return;

        let address_rewards = 0;

        if (table::contains(table, address)) {
            address_rewards = *table::borrow(table, address);
            table::remove(table, address);
        };

        table::add(table, address, address_rewards + rewards_to_add);
    }

    fun remove_rewards(table: &mut Table<address, u64>, address: address): u64 {
        if (table::contains(table, address)) {
            table::remove(table, address)
        } else {
            0
        }
    }

    fun calculate_rewards<NFT, COIN>(pool: &StakingPool<NFT, COIN>, ticket: &StakingTicket, clock: &Clock): u64 {
        (min(pool.end_time,clock::timestamp_ms(clock)) - ticket.start_time) / 1000 / 60 / 60 / 24 * pool.rewards_per_day
    }

    fun borrow_pool_rewards_mut<NFT, COIN>(pool: &mut StakingPool<NFT, COIN>): &mut Table<address, u64> {
        dof::borrow_mut(&mut pool.id, rewards_key())
    }

    fun borrow_hub_rewards_mut(hub: &mut StakingHub): &mut Table<address, u64> {
        dof::borrow_mut(&mut hub.id, rewards_key())
    }

    fun borrow_hub_pools_mut(hub: &mut StakingHub): &mut Table<ID, bool> {
        dof::borrow_mut(&mut hub.id, pools_key())
    }

    fun check_hub_version(hub: &StakingHub) {
        assert!(hub.version == VERSION, EWrongVersion);
    }

    fun check_pool_version<NFT, COIN>(pool: &StakingPool<NFT, COIN>) {
        assert!(pool.version == VERSION, EWrongVersion);
    }
}