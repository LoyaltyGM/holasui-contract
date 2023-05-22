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
    // TODO: add versioning/migration
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
    const EInsufficientPoints: u64 = 2;
    const EStakingEnded: u64 = 3;

    // ======== Types =========

    struct STAKING has drop {}

    struct AdminCap has key, store {
        id: UID,
    }

    // Only one instance of this struct is created
    struct StakingHub has key {
        id: UID,
        balance: Balance<SUI>,
        /// Total staked nfts per all pools
        staked: u64,

        // dof

        // Pools
        // pools: Table<ID, bool>,

        // Points from each pool
        // points: Table<address, u64>, // total points from all pools
    }

    // Creatable by admin
    struct StakingPool<phantom T, phantom COIN> has key {
        id: UID,
        name: String,
        /// End time of staking in milliseconds
        end_time: u64,
        fee_for_stake: u64,
        fee_for_unstake: u64,
        fee_for_claim: u64,
        points_per_day: u64,
        /// Total staked nfts per current pool
        staked: u64,
        balance: Balance<COIN>,

        // dof

        // Points for current pool
        // points: Table<address, u64>,
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
        points: u64,
    }

    struct Claimed has copy, drop {
        nft_id: ID,
        points: u64,
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
            balance: balance::zero(),
            staked: 0,
        };
        dof::add<String, Table<address, u64>>(&mut hub.id, points_key(), table::new<address, u64>(ctx));
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
        let amount = balance::value(&hub.balance);
        assert!(amount > 0, EZeroBalance);

        pay::keep(coin::take(&mut hub.balance, amount, ctx), ctx);
    }

    entry fun deposit_pool<T, COIN>(pool: &mut StakingPool<T, COIN>, coin: Coin<COIN>) {
        coin::put(&mut pool.balance, coin);
    }

    entry fun withdraw_pool<T, COIN>(_: &AdminCap, pool: &mut StakingPool<T, COIN>, ctx: &mut TxContext) {
        let amount = balance::value(&pool.balance);
        assert!(amount > 0, EZeroBalance);

        pay::keep(coin::take(&mut pool.balance, amount, ctx), ctx);
    }

    entry fun create_pool<T, COIN>(_: &AdminCap, hub: &mut StakingHub, name: String, ctx: &mut TxContext) {
        let pool = StakingPool<T, COIN> {
            id: object::new(ctx),
            name,
            end_time: 0,
            fee_for_stake: FEE_FOR_STAKE,
            fee_for_unstake: FEE_FOR_UNSTAKE,
            points_per_day: POINTS_PER_DAY,
            fee_for_claim: FEE_FOR_CLAIM,
            staked: 0,
            balance: balance::zero<COIN>(),
        };
        dof::add<String, Table<address, u64>>(&mut pool.id, points_key(), table::new<address, u64>(ctx));

        // Add poolId to list of pools
        table::add(borrow_hub_pools_mut(hub), object::id(&pool), true);

        share_object(pool);
    }

    entry fun set_fee_for_stake<T, COIN>(_: &AdminCap, pool: &mut StakingPool<T, COIN>, fee: u64) {
        pool.fee_for_stake = fee;
    }

    entry fun set_fee_for_unstake<T, COIN>(_: &AdminCap, pool: &mut StakingPool<T, COIN>, fee: u64) {
        pool.fee_for_unstake = fee;
    }

    entry fun set_points_per_minute<T, COIN>(_: &AdminCap, pool: &mut StakingPool<T, COIN>, points: u64) {
        pool.points_per_day = points;
    }

    // ======== User functions =========

    entry fun stake<T: key + store, COIN>(
        nft: T,
        hub: &mut StakingHub,
        pool: &mut StakingPool<T, COIN>,
        coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
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

        dof::add<ID, T>(&mut pool.id, nft_id, nft);
        transfer(ticket, sender(ctx));
    }

    entry fun unstake<T: key + store, COIN>(
        ticket: StakingTicket,
        hub: &mut StakingHub,
        pool: &mut StakingPool<T, COIN>,
        coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        handle_payment(hub, coin, pool.fee_for_unstake, ctx);

        let points = calculate_points(pool, &ticket, clock);

        add_points(borrow_hub_points_mut(hub), sender(ctx), points);
        add_points(borrow_pool_points_mut(pool), sender(ctx), points);

        hub.staked = if (hub.staked > 0) hub.staked - 1 else 0 ;
        pool.staked = if (pool.staked > 0) pool.staked - 1 else 0 ;

        let StakingTicket { id, nft_id, start_time: _, name: _, url: _, } = ticket;

        let nft = dof::remove<ID, T>(&mut pool.id, nft_id);

        emit(Unstaked {
            nft_id,
            points,
        });

        object::delete(id);
        public_transfer(nft, sender(ctx));
    }

    entry fun claim<T: key + store, COIN>(
        ticket: &mut StakingTicket,
        hub: &mut StakingHub,
        pool: &mut StakingPool<T, COIN>,
        coin: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        handle_payment(hub, coin, pool.fee_for_claim, ctx);

        let points = calculate_points(pool, ticket, clock);

        add_points(borrow_hub_points_mut(hub), sender(ctx), points);
        add_points(borrow_pool_points_mut(pool), sender(ctx), points);

        emit(Claimed {
            nft_id: ticket.nft_id,
            points,
        });

        ticket.start_time = clock::timestamp_ms(clock);
    }


    // ======== View functions =========

    // ======== Utility functions =========

    fun points_key(): String {
        utf8(b"points")
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

    fun add_points(table: &mut Table<address, u64>, address: address, points_to_add: u64) {
        if (points_to_add == 0) return;

        let address_points = 0;

        if (table::contains(table, address)) {
            address_points = *table::borrow(table, address);
            table::remove(table, address);
        };

        table::add(table, address, address_points + points_to_add);
    }

    fun sub_points(table: &mut Table<address, u64>, address: address, points_to_sub: u64) {
        if (points_to_sub == 0) return;

        assert!(
            table::contains(table, address) && *table::borrow(table, address) >= points_to_sub,
            EInsufficientPoints
        );
        let address_points = table::borrow_mut(table, address);
        *address_points = *address_points - points_to_sub;
    }

    fun calculate_points<T, COIN>(pool: &StakingPool<T, COIN>, ticket: &StakingTicket, clock: &Clock): u64 {
        (min(pool.end_time,clock::timestamp_ms(clock)) - ticket.start_time) / 1000 / 60 / 60 / 24 * pool.points_per_day
    }

    fun borrow_pool_points_mut<T, COIN>(pool: &mut StakingPool<T, COIN>): &mut Table<address, u64> {
        dof::borrow_mut(&mut pool.id, points_key())
    }

    fun borrow_hub_points_mut(hub: &mut StakingHub): &mut Table<address, u64> {
        dof::borrow_mut(&mut hub.id, points_key())
    }

    fun borrow_hub_pools_mut(hub: &mut StakingHub): &mut Table<ID, bool> {
        dof::borrow_mut(&mut hub.id, pools_key())
    }
}