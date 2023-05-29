/// Main module of the holasui contract.
module holasui::holasui {
    use std::string::{String, utf8};

    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::transfer::{public_transfer, share_object};
    use sui::tx_context::{sender, TxContext};

    friend holasui::loyalty;
    friend holasui::staking;
    friend holasui::escrow;

    // ======== Constants =========

    const VERSION: u64 = 1;

    // ======== Errors =========


    // ======== Types =========

    struct AdminCap has key, store {
        id: UID,
    }

    struct HolasuiHub has key {
        id: UID,
        points_for_stake: u64,
        points_for_swap: u64,
        points_for_done_campaign: u64,
        points: Table<address, u64>
    }

    // ======== Functions =========

    fun init(ctx: &mut TxContext) {
        public_transfer(AdminCap {
            id: object::new(ctx),
        }, sender(ctx));
        share_object(HolasuiHub {
            id: object::new(ctx),
            points_for_stake: 10,
            points_for_swap: 10,
            points_for_done_campaign: 10,
            points: table::new(ctx)
        });
    }

    // ======== Admin Functions =========

    entry fun update_points_for_stake(_: &AdminCap, hub: &mut HolasuiHub, points: u64) {
        hub.points_for_stake = points;
    }

    entry fun update_points_for_done_campaign(_: &AdminCap, hub: &mut HolasuiHub, points: u64) {
        hub.points_for_done_campaign = points;
    }

    // ======== Write Functions =========

    public(friend) fun add_points_for_address(hub: &mut HolasuiHub, points: u64, address: address) {
        if (!table::contains(&hub.points, address)) {
            table::add(&mut hub.points, address, points);
        } else {
            let current_points = table::borrow_mut(&mut hub.points, address);
            *current_points = *current_points + points;
        }
    }

    // ======== View Functions =========

    public(friend) fun points_for_stake(hub: &HolasuiHub): u64 {
        hub.points_for_stake
    }

    public(friend) fun points_for_swap(hub: &HolasuiHub): u64 {
        hub.points_for_swap
    }

    public(friend) fun points_for_done_campaign(hub: &HolasuiHub): u64 {
        hub.points_for_done_campaign
    }

    public(friend) fun project_url(): String {
        utf8(b"https://www.holasui.app")
    }

    public(friend) fun version(): u64 {
        VERSION
    }
}
