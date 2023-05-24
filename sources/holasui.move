module holasui::holasui {
    use sui::object::{Self, UID};
    use sui::transfer::public_transfer;
    use sui::tx_context::{sender, TxContext};

    const VERSION: u64 = 1;

    struct AdminCap has key, store {
        id: UID,
    }

    fun init(ctx: &mut TxContext) {
        public_transfer(AdminCap {
            id: object::new(ctx),
        }, sender(ctx));
    }

    public fun version(): u64 {
        VERSION
    }
}
