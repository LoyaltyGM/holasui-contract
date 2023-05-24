module holasui::loyalty {
    use std::string::String;

    use sui::balance::Balance;
    use sui::object::{UID, ID};
    use sui::sui::SUI;
    use sui::table_vec::TableVec;
    use sui::tx_context::TxContext;
    use sui::url::Url;
    use sui::vec_map::VecMap;

    // ======== Constants =========

    // ======== Errors =========

    // ======== Types =========

    struct LOYALTY has drop {}

    struct LoyaltyHub has key {
        id: UID,
        balance: Balance<SUI>,
        allowlist: TableVec<address>,
        // dof
        // allowlist: [user] -> true
    }

    struct Space has key {
        id: UID,
        version: u64,
        name: String,
        description: String,
        image_url: Url,
        website_url: Url,
        twitter_url: Url,

        // dof
        // [campaign name] -> Campaign
    }

    struct Campaign has key, store {
        id: UID,
        name: String,
        description: String,
        image_url: Url,
        end_time: u64,
        completed_count: u64,
        quests: VecMap<ID, Quest>,
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

        //dof
        // done: Table<address, bool>
    }

    struct Reward has key, store {
        id: UID,
        name: String,
        description: String,
        image_url: Url,
        campaign_id: ID,
    }

    fun init(_: LOYALTY, ctx: &mut TxContext) {}
}
