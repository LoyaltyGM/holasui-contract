module holasui::loyalty {
    use std::string::{Self, String, utf8};
    use std::vector;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::Coin;
    use sui::display;
    use sui::event::emit;
    use sui::object::{Self, UID, ID};
    use sui::package;
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::table_vec::{Self, TableVec};
    use sui::transfer::{public_transfer, share_object, transfer};
    use sui::tx_context::{TxContext, sender};
    use sui::url::{Self, Url};

    use holasui::holasui::{Self, AdminCap, project_url, version, HolasuiHub};
    use holasui::utils::{withdraw_balance, handle_payment};

    // ======== Constants =========

    const FEE_FOR_CREATING_CAMPAIGN: u64 = 1000000000;

    // ======== Errors =========

    const EWrongVersion: u64 = 0;
    const ENotUpgrade: u64 = 1;
    const ENotSpaceCreator: u64 = 2;
    const ENotSpaceAdmin: u64 = 3;
    const EInvalidTime: u64 = 4;
    const EQuestAlreadyDone: u64 = 5;
    const EQuestNotDone: u64 = 6;
    const ECampaignAlreadyDone: u64 = 7;


    // ======== Types =========

    struct LOYALTY has drop {}

    struct Verifier has key, store {
        id: UID,
    }

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
        campaigns: Table<ID, Campaign>,
    }

    struct SpaceAdminCap has key, store {
        id: UID,
        name: String,
        space_id: ID,
    }

    struct Campaign has key, store {
        id: UID,
        name: String,
        description: String,
        reward_image_url: Url,
        end_time: u64,
        quests: vector<Quest>,
        done: Table<address, bool>
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
        space_id: ID,
        campaign_id: ID,
    }

    // ======== Events =========

    struct QuestDone has copy, drop {
        space_id: ID,
        campaign_id: ID,
        quest_index: u64,
    }

    struct CampaignDone has copy, drop {
        space_id: ID,
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
        public_transfer(Verifier {
            id: object::new(ctx),
        }, sender(ctx));
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

    entry fun add_space_creator(
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
        handle_space_create(hub, sender(ctx));

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
        hub: &mut LoyaltyHub,
        coin: Coin<SUI>,
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

        handle_payment(&mut hub.balance, coin, hub.fee_for_creating_campaign, ctx);

        let campaign = Campaign {
            id: object::new(ctx),
            name,
            description,
            reward_image_url: url::new_unsafe(string::to_ascii(image_url)),
            end_time,
            quests: vector::empty(),
            done: table::new(ctx)
        };

        table::add(&mut space.campaigns, object::id(&campaign), campaign);
    }

    entry fun remove_campaign(admin_cap: &SpaceAdminCap, space: &mut Space, campaign_id: ID) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let Campaign {
            id,
            name: _,
            description: _,
            reward_image_url: _,
            end_time: _,
            quests,
            done
        } = table::remove(&mut space.campaigns, campaign_id);

        vector::destroy_empty(quests);
        table::drop(done);
        object::delete(id)
    }

    entry fun update_campaign_name(admin_cap: &SpaceAdminCap, space: &mut Space, campaign_id: ID, name: String) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);
        campaign.name = name;
    }

    entry fun update_campaign_description(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_id: ID,
        description: String
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);
        campaign.description = description;
    }

    entry fun update_campaign_reward_image_url(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_id: ID,
        image_url: String
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);
        campaign.reward_image_url = url::new_unsafe(string::to_ascii(image_url));
    }

    entry fun update_campaign_end_time(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_id: ID,
        end_time: u64
    ) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);

        campaign.end_time = end_time;
    }

    entry fun create_quest(
        admin_cap: &SpaceAdminCap,
        space: &mut Space,
        campaign_id: ID,
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

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);

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

        vector::push_back(&mut campaign.quests, quest);
    }

    entry fun remove_quest(admin_cap: &SpaceAdminCap, space: &mut Space, campaign_id: ID, quest_index: u64) {
        check_space_version(space);
        check_space_admin(admin_cap, space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);
        let Quest {
            name: _,
            description: _,
            call_to_action_url: _,
            package_id: _,
            module_name: _,
            function_name: _,
            arguments: _,
            done,
        } = vector::remove(&mut campaign.quests, quest_index);

        table::drop(done);
    }

    // ======== Verifier functions =========

    entry fun verify_campaign_quest(
        _: &Verifier,
        space: &mut Space,
        campaign_id: ID,
        quest_index: u64,
        user: address,
        clock: &Clock,
    ) {
        check_space_version(space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);
        assert!(clock::timestamp_ms(clock) <= campaign.end_time, EInvalidTime);

        let quest = vector::borrow_mut(&mut campaign.quests, quest_index);
        assert!(!table::contains(&quest.done, user), EQuestAlreadyDone);

        emit(QuestDone {
            space_id: object::uid_to_inner(&space.id),
            campaign_id,
            quest_index
        });

        table::add(&mut quest.done, user, true);
    }

    // ======== User functions =========

    entry fun claim_campaign_reward(
        holasui_hub: &mut HolasuiHub,
        space: &mut Space,
        campaign_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        check_space_version(space);

        let campaign = table::borrow_mut(&mut space.campaigns, campaign_id);

        assert!(clock::timestamp_ms(clock) <= campaign.end_time, EInvalidTime);
        assert!(!table::contains(&campaign.done, sender(ctx)), ECampaignAlreadyDone);
        check_campaign_quests_done(campaign, sender(ctx));

        emit(CampaignDone {
            space_id: object::uid_to_inner(&space.id),
            campaign_id
        });

        let hola_points = holasui::points_for_done_campaign(holasui_hub);
        holasui::add_points_for_address(holasui_hub, hola_points,sender(ctx));

        table::add(&mut campaign.done, sender(ctx), true);
        transfer(Reward {
            id: object::new(ctx),
            name: campaign.name,
            description: campaign.description,
            image_url: campaign.reward_image_url,
            space_id: object::id(space),
            campaign_id
        }, sender(ctx));
    }


    // ======== Utility functions =========

    fun handle_space_create(hub: &mut LoyaltyHub, creator: address) {
        assert!(table::contains(&hub.space_creators_allowlist, creator) &&
            *table::borrow(&hub.space_creators_allowlist, creator) > 0,
            ENotSpaceCreator
        );

        let current_allowed_spaces_amount = table::borrow_mut(&mut hub.space_creators_allowlist, creator);
        *current_allowed_spaces_amount = *current_allowed_spaces_amount - 1;
    }

    fun check_campaign_quests_done(campaign: &Campaign, address: address) {
        let quests = &campaign.quests;

        let i = 0;
        while (i < vector::length(quests)) {
            let quest = vector::borrow(quests, i);
            assert!(table::contains(&quest.done, address), EQuestNotDone);
            i = i + 1;
        }
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
