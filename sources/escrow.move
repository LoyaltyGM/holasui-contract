module holasui::escrow {
    use std::string::{utf8, String};
    use std::vector;

    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::object_bag::{Self, ObjectBag};
    use sui::sui::SUI;
    use sui::transfer::{share_object, public_transfer};
    use sui::tx_context::{TxContext, sender};

    // ======== Errors =========
    const EWrongOwner: u64 = 0;
    const EWrongRecipient: u64 = 1;
    const EWrongObject: u64 = 2;
    const EWrongCoinAmount: u64 = 3;
    const EInvalidOffer: u64 = 4;
    const EInactiveOffer: u64 = 5;

    // ======== Types =========

    /// An object held in escrow
    struct EscrowOffer has key, store {
        id: UID,
        active: bool,
        object_bag: ObjectBag,
        //
        creator: address,
        creator_objects: vector<ID>,
        creator_coin_amount: u64,
        //
        recipient: address,
        recipient_objects: vector<ID>,
        recipient_coin_amount: u64,
    }


    // ======== Functions =========

    // ======== Creator of Offer functions ========

    public fun create(
        creator_objects: vector<ID>,
        creator_coin_amount: u64,
        recipient: address,
        recipient_objects: vector<ID>,
        recipient_coin_amount: u64,
        ctx: &mut TxContext
    ): EscrowOffer {
        let id = object::new(ctx);

        EscrowOffer {
            id,
            active: false,
            object_bag: object_bag::new(ctx),
            creator: sender(ctx),
            creator_objects,
            creator_coin_amount,
            recipient,
            recipient_objects,
            recipient_coin_amount,
        }
    }

    public fun update_creator_objects<T: key + store>(
        offer: EscrowOffer,
        item: T,
        ctx: &mut TxContext
    ): EscrowOffer {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(vector::contains(&offer.creator_objects, &object::id(&item)), EWrongObject);

        object_bag::add<ID, T>(&mut offer.object_bag, object::id(&item), item);

        offer
    }

    public fun update_creator_coin(
        offer: EscrowOffer,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ): EscrowOffer {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(coin::value(&coin) == offer.creator_coin_amount, EWrongCoinAmount);

        object_bag::add<String, Coin<SUI>>(&mut offer.object_bag, key_creator_coin(), coin);

        offer
    }

    public fun share_offer(
        offer: EscrowOffer,
        ctx: &mut TxContext
    ) {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        check_creator_offer(&mut offer);

        offer.active = true;

        share_object(offer);
    }

    public fun cancel_creator_offer(
        offer: &mut EscrowOffer,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        transfer_creator_offers(offer, sender(ctx));

        offer.active = false;
    }

    // ======== Recipient of Offer functions ========

    public fun update_recipient_objects<T: key + store>(
        offer: &mut EscrowOffer,
        item: T,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        assert!(vector::contains(&offer.recipient_objects, &object::id(&item)), EWrongObject);

        object_bag::add<ID, T>(&mut offer.object_bag, object::id(&item), item);
    }

    public fun update_recipient_coin(
        offer: &mut EscrowOffer,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        assert!(coin::value(&coin) == offer.recipient_coin_amount, EWrongCoinAmount);

        object_bag::add<String, Coin<SUI>>(&mut offer.object_bag, key_recipient_coin(), coin);
    }

    public fun cancel_recipient_offer(
        offer: &mut EscrowOffer,
        ctx: &mut TxContext
    ) {
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        transfer_recipient_offers(offer, sender(ctx));
    }

    public fun exchange(
        offer: &mut EscrowOffer,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        check_creator_offer(offer);
        check_recipient_offer(offer);

        let recipient = offer.recipient;
        transfer_creator_offers(offer, recipient);

        let creator = offer.creator;
        transfer_recipient_offers(offer, creator);
    }


    // ======== View functions =========

    public fun key_creator_coin(): String {
        utf8(b"creator_coin")
    }

    public fun key_recipient_coin(): String {
        utf8(b"recipient_coin")
    }


    // ======== Utility functions =========

    fun check_creator_offer(offer: &mut EscrowOffer) {
        let i = 0;
        while (i < vector::length(&offer.creator_objects)) {
            assert!(
                object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.creator_objects, i)),
                EInvalidOffer
            );
        };

        assert!(
            coin::value(
                object_bag::borrow<String, Coin<SUI>>(&offer.object_bag, key_creator_coin())
            ) == offer.creator_coin_amount,
            EInvalidOffer
        );
    }

    fun check_recipient_offer(offer: &mut EscrowOffer) {
        let i = 0;
        while (i < vector::length(&offer.recipient_objects)) {
            assert!(
                object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.recipient_objects, i)),
                EInvalidOffer
            );
        };

        assert!(
            coin::value(
                object_bag::borrow<String, Coin<SUI>>(&offer.object_bag, key_recipient_coin())
            ) == offer.recipient_coin_amount,
            EInvalidOffer
        );
    }

    fun transfer_creator_offers(offer: &mut EscrowOffer, to: address) {
        // let i = 0;
        // while (i < vector::length(&offer.creator_objects)) {
        //     if (object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.creator_objects, i))) {
        //         let obj = object_bag::remove(&mut offer.object_bag, *vector::borrow(&offer.creator_objects, i));
        //         public_transfer(obj, to);
        //     }
        // };

        if (object_bag::contains<String>(&offer.object_bag, key_creator_coin())) {
            let coin = object_bag::remove<String, Coin<SUI>>(&mut offer.object_bag, key_creator_coin());
            public_transfer(coin, to);
        };
    }

    fun transfer_recipient_offers(offer: &mut EscrowOffer, to: address) {
        // let i = 0;
        // while (i < vector::length(&offer.recipient_objects)) {
        //     if (object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.recipient_objects, i))) {
        //         object_bag::remove(&mut offer.object_bag, *vector::borrow(&offer.recipient_objects, i));
        //         public_transfer(obj, to);
        //     }
        // };

        if (object_bag::contains<String>(&offer.object_bag, key_recipient_coin())) {
            let coin = object_bag::remove<String, Coin<SUI>>(&mut offer.object_bag, key_recipient_coin());
            public_transfer(coin, to);
        };
    }
}
