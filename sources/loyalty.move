module holasui::loyalty {
    use std::string::{String, utf8};

    use sui::balance::{Self, Balance};
    use sui::display;
    use sui::object::{Self, UID, ID};
    use sui::package;
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::transfer::{public_transfer, share_object};
    use sui::tx_context::{TxContext, sender};
    use sui::url::Url;

    use holasui::holasui::{AdminCap, project_url};
    use holasui::utils::withdraw_balance;

    // ======== Constants =========

    const FEE_FOR_CREATING_CAMPAIGN: u64 = 1000000000;

    // ======== Errors =========

    // ======== Types =========

    struct LOYALTY has drop {}

    struct LoyaltyHub has key {
        id: UID,
        balance: Balance<SUI>,
        fee_for_creating_campaign: u64,
        /// The amount of spaces that can be created by a single address
        space_creators: Table<address, u64>,
    }

    struct Space has key {
        id: UID,
        version: u64,
        name: String,
        description: String,
        image_url: Url,
        website_url: Url,
        twitter_url: Url,
        campaigns: Table<ID, Campaign>,
    }

    struct SpaceAdminCap has key, store {
        id: UID,
        name: String,
        image_url: Url,
        space_id: ID,
    }

    struct Campaign has key, store {
        id: UID,
        name: String,
        description: String,
        image_url: Url,
        end_time: u64,
        completed_count: u64,
        quests: Table<ID, Quest>,
    }

    struct Quest has key, store {
        id: UID,
        /// The name of the quest
        name: String,
        /// The description of the quest
        description: String,
        /// Link to information about the quest
        call_to_action_url: Url,
        /// The ID of the package that contains the function that needs to be executed
        package_id: ID,
        /// The name of the module that contains the function that needs to be executed
        module_name: String,
        /// The name of the function that needs to be executed
        function_name: String,
        /// The arguments that need to be passed to the function
        arguments: vector<String>,

        done: Table<address, bool>
    }

    struct Reward has key, store {
        id: UID,
        name: String,
        description: String,
        image_url: Url,
        campaign_id: ID,
    }

    // ======== Functions =========

    fun init(otw: LOYALTY, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        // Reward display
        let reward_keys = vector[
            utf8(b"name"),
            utf8(b"description"),
            utf8(b"image_url"),
            utf8(b"project_url"),
        ];
        let reward_values = vector[
            utf8(b"{name}"),
            utf8(b"{description}"),
            utf8(b"{image_url}"),
            project_url()
        ];
        let reward_display = display::new_with_fields<Reward>(
            &publisher, reward_keys, reward_values, ctx
        );
        display::update_version(&mut reward_display);


        public_transfer(publisher, sender(ctx));
        public_transfer(reward_display, sender(ctx));
        share_object(LoyaltyHub {
            id: object::new(ctx),
            balance: balance::zero(),
            fee_for_creating_campaign: FEE_FOR_CREATING_CAMPAIGN,
            space_creators: table::new(ctx),
        })
    }

    // ======== Admin functions =========

    entry fun update_space_creators(_: &AdminCap, hub: &mut LoyaltyHub, creator: address, allowed_spaces_amount: u64) {
        if (!table::contains(&hub.space_creators, creator)) {
            table::add(&mut hub.space_creators, creator, allowed_spaces_amount);
        } else {
            let current_allowed_spaces_amount = table::borrow_mut(&mut hub.space_creators, creator);
            *current_allowed_spaces_amount = allowed_spaces_amount;
        }
    }

    entry fun update_fee_for_creating_campaign(_: &AdminCap, hub: &mut LoyaltyHub, fee: u64) {
        hub.fee_for_creating_campaign = fee;
    }

    entry fun withdraw(_: &AdminCap, hub: &mut LoyaltyHub, ctx: &mut TxContext) {
        withdraw_balance(&mut hub.balance, ctx);
    }

    // ======== SpaceAdmin functions =========


    // ======== User functions =========

    // ======== Utility functions =========
}
