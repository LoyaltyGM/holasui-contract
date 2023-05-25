module holasui::loyalty {
    use std::string::{Self, String, utf8};

    use sui::balance::{Self, Balance};
    use sui::display;
    use sui::object::{Self, UID, ID};
    use sui::package;
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::table_vec::{Self, TableVec};
    use sui::transfer::{public_transfer, share_object};
    use sui::tx_context::{TxContext, sender};
    use sui::url::{Self, Url};

    use holasui::holasui::{AdminCap, project_url, version};
    use holasui::utils::withdraw_balance;

    // ======== Constants =========

    const FEE_FOR_CREATING_CAMPAIGN: u64 = 1000000000;

    // ======== Errors =========

    const EWrongVersion: u64 = 0;
    const ENotUpgrade: u64 = 1;
    const ENotSpaceCreator: u64 = 2;
    const ENotSpaceAdmin: u64 = 3;
    const EInvalidTime: u64 = 4;

    // ======== Types =========

    struct LOYALTY has drop {}

    struct LoyaltyHub has key {
        id: UID,
        version: u64,
        balance: Balance<SUI>,
        fee_for_creating_campaign: u64,
        /// The amount of spaces that can be created by a single address
        space_creators_allowlist: Table<address, u64>,
        spaces: TableVec<ID>
    }

    struct Space has key {
        id: UID,
        version: u64,
        name: String,
        description: String,
        image_url: Url,
        website_url: Url,
        twitter_url: Url,
        campaigns: Table<String, Campaign>,
    }

    struct SpaceAdminCap has key, store {
        id: UID,
        name: String,
        space_id: ID,
    }

    struct Campaign has store {
        name: String,
        description: String,
        reward_image_url: Url,
        start_time: u64,
        end_time: u64,
        completed_count: u64,
        quests: Table<String, Quest>,
    }

    struct Quest has store {
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
            version: version(),
            balance: balance::zero(),
            fee_for_creating_campaign: FEE_FOR_CREATING_CAMPAIGN,
            space_creators_allowlist: table::new(ctx),
            spaces: table_vec::empty<ID>(ctx),
        })
    }

    // ======== Admin functions =========

    entry fun update_space_creators(
        _: &AdminCap,
        hub: &mut LoyaltyHub,
        creator: address,
        allowed_spaces_amount: u64
    ) {
        check_hub_version(hub);

        if (!table::contains(&hub.space_creators_allowlist, creator)) {
            table::add(&mut hub.space_creators_allowlist, creator, allowed_spaces_amount);
        } else {
            let current_allowed_spaces_amount = table::borrow_mut(&mut hub.space_creators_allowlist, creator);
            *current_allowed_spaces_amount = allowed_spaces_amount;
        }
    }

    entry fun update_fee_for_creating_campaign(_: &AdminCap, hub: &mut LoyaltyHub, fee: u64) {
        check_hub_version(hub);

        hub.fee_for_creating_campaign = fee;
    }

    entry fun withdraw(_: &AdminCap, hub: &mut LoyaltyHub, ctx: &mut TxContext) {
        check_hub_version(hub);

        withdraw_balance(&mut hub.balance, ctx);
    }

    entry fun migrate_hub(_: &AdminCap, hub: &mut LoyaltyHub) {
        assert!(hub.version < version(), ENotUpgrade);

        hub.version = version();
    }

    entry fun migrate_space(_: &AdminCap, space: &mut Space) {
        assert!(space.version < version(), ENotUpgrade);

        space.version = version();
    }

    // ======== SpaceAdmin functions =========

    // ======== Space functions

    entry fun create_space(
        hub: &mut LoyaltyHub,
        name: String,
        description: String,
        image_url: String,
        website_url: String,
        twitter_url: String,
        ctx: &mut TxContext
    ) {
        check_hub_version(hub);
        update_space_creator(hub, sender(ctx));

        let space = Space {
            id: object::new(ctx),
            version: version(),
            name,
            description,
            image_url: url::new_unsafe(string::to_ascii(image_url)),
            website_url: url::new_unsafe(string::to_ascii(website_url)),
            twitter_url: url::new_unsafe(string::to_ascii(twitter_url)),
            campaigns: table::new(ctx),
        };

        let admin_cap = SpaceAdminCap {
            id: object::new(ctx),
            name: space.name,
            space_id: object::id(&space),
        };

        table_vec::push_back(&mut hub.spaces, object::id(&space));

        share_object(space);
        public_transfer(admin_cap, sender(ctx));
    }

    entry fun update_space_name(admin_cap: &SpaceAdminCap, space: &mut Space, name: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        space.name = name;
    }

    entry fun update_space_description(admin_cap: &SpaceAdminCap, space: &mut Space, description: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        space.description = description;
    }

    entry fun update_space_image_url(admin_cap: &SpaceAdminCap, space: &mut Space, image_url: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        space.image_url = url::new_unsafe(string::to_ascii(image_url));
    }

    entry fun update_space_website_url(admin_cap: &SpaceAdminCap, space: &mut Space, website_url: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        space.website_url = url::new_unsafe(string::to_ascii(website_url));
    }

    entry fun update_space_twitter_url(admin_cap: &SpaceAdminCap, space: &mut Space, twitter_url: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        space.twitter_url = url::new_unsafe(string::to_ascii(twitter_url));
    }

    // ======== Campaign functions

    entry fun create_campaign(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        name: String,
        description: String,
        image_url: String,
        start_time: u64,
        end_time: u64,
        ctx: &mut TxContext
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);
        assert!(start_time < end_time, EInvalidTime);

        let campaign = Campaign {
            name,
            description,
            reward_image_url: url::new_unsafe(string::to_ascii(image_url)),
            start_time,
            end_time,
            completed_count: 0,
            quests: table::new(ctx),
        };

        table::add(&mut space.campaigns, campaign.name, campaign);
    }

    entry fun remove_campaign(admin_cap: &SpaceAdminCap, space: &mut Space, campaign_name: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let Campaign {
            name: _,
            description: _,
            reward_image_url: _,
            start_time: _,
            end_time: _,
            completed_count: _,
            quests,
        } = table::remove(&mut space.campaigns, campaign_name);

        table::destroy_empty(quests);
    }

    entry fun update_campaign_name(admin_cap: &SpaceAdminCap, space: &mut Space, campaign_name: String, name: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_name);
        campaign.name = name;
    }

    entry fun update_campaign_description(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_name: String,
        description: String
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_name);
        campaign.description = description;
    }

    entry fun update_campaign_reward_image_url(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_name: String,
        image_url: String
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_name);
        campaign.reward_image_url = url::new_unsafe(string::to_ascii(image_url));
    }

    entry fun update_campaign_start_time(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_name: String,
        start_time: u64
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_name);
        assert!(start_time < campaign.end_time, EInvalidTime);

        campaign.start_time = start_time;
    }

    entry fun update_campaign_end_time(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_name: String,
        end_time: u64
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_name);
        assert!(campaign.start_time < end_time, EInvalidTime);

        campaign.end_time = end_time;
    }

    entry fun create_quest(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_name: String,
        name: String,
        description: String,
        call_to_action_url: String,
        package_id: ID,
        module_name: String,
        function_name: String,
        arguments: vector<String>,
        ctx: &mut TxContext
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_name);

        let quest = Quest {
            name,
            description,
            call_to_action_url: url::new_unsafe(string::to_ascii(call_to_action_url)),
            package_id,
            module_name,
            function_name,
            arguments,
            done: table::new(ctx)
        };

        table::add(&mut campaign.quests, quest.name, quest);
    }

    entry fun remove_quest(admin_cap: &SpaceAdminCap, space: &mut Space, campaign_name: String, quest_name: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_name);
        let Quest {
            name: _,
            description: _,
            call_to_action_url: _,
            package_id: _,
            module_name: _,
            function_name: _,
            arguments: _,
            done,
        } = table::remove(&mut campaign.quests, quest_name);

        table::drop(done);
    }

    // ======== User functions =========

    // ======== Utility functions =========

    fun update_space_creator(hub: &mut LoyaltyHub, creator: address) {
        assert!(table::contains(&hub.space_creators_allowlist, creator) &&
            *table::borrow(&hub.space_creators_allowlist, creator) > 0,
            ENotSpaceCreator
        );

        let current_allowed_spaces_amount = table::borrow_mut(&mut hub.space_creators_allowlist, creator);
        *current_allowed_spaces_amount = *current_allowed_spaces_amount - 1;
    }

    fun check_hub_version(hub: &LoyaltyHub) {
        assert!(hub.version == version(), EWrongVersion);
    }

    fun check_space_version(space: &Space) {
        assert!(space.version == version(), EWrongVersion);
    }

    fun check_space_admin(admin_cap: &SpaceAdminCap, space: &Space) {
        assert!(admin_cap.space_id == object::id(space), ENotSpaceAdmin);
    }
}
