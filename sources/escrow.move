module holasui::escrow {
    use std::string::{utf8, String};
    use std::vector;

    use sui::coin::{Self, Coin};
    use sui::dynamic_object_field as dof;
    use sui::object::{Self, ID, UID};
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
        creator_object_offers: vector<ID>,
        creator_coin_offer_amount: u64,
        recipient: address,
        recipient_object_offers: vector<ID>,
        recipient_coin_offer_amount: u64,
        ctx: &mut TxContext
    ): EscrowOffer {
        let id = object::new(ctx);

        EscrowOffer {
            id,
            active: false,
            creator: sender(ctx),
            creator_objects: creator_object_offers,
            creator_coin_amount: creator_coin_offer_amount,
            recipient,
            recipient_objects: recipient_object_offers,
            recipient_coin_amount: recipient_coin_offer_amount,
        }
    }

    public fun update_creator_objects<T: key + store>(
        offer: EscrowOffer,
        item: T,
        ctx: &mut TxContext
    ): EscrowOffer {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(vector::contains(&offer.creator_objects, &object::id(&item)), EWrongObject);

        dof::add<ID, T>(&mut offer.id, object::id(&item), item);

        offer
    }

    public fun update_creator_coin(
        offer: EscrowOffer,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ): EscrowOffer {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(coin::value(&coin) == offer.creator_coin_amount, EWrongCoinAmount);

        dof::add<String, Coin<SUI>>(&mut offer.id, key_creator_coin(), coin);

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

    public fun cancel_creator_offer<T: key + store>(
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
        assert!(sender(ctx) == offer.recipient, EWrongOwner);

        assert!(vector::contains(&offer.recipient_objects, &object::id(&item)), EWrongObject);

        dof::add<ID, T>(&mut offer.id, object::id(&item), item);
    }

    public fun update_recipient_coin(
        offer: &mut EscrowOffer,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongOwner);

        assert!(coin::value(&coin) == offer.recipient_coin_amount, EWrongCoinAmount);

        dof::add<String, Coin<SUI>>(&mut offer.id, key_recipient_coin(), coin);
    }

    public fun cancel_recipient_offer(
        offer: &mut EscrowOffer,
        ctx: &mut TxContext
    ) {
        assert!(sender(ctx) == offer.recipient, EWrongOwner);

        transfer_recipient_offers(offer, sender(ctx));
    }

    public fun exchange(
        offer: &mut EscrowOffer,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongOwner);

        check_creator_offer(offer);
        check_recipient_offer(offer);

        transfer_creator_offers(offer, offer.recipient);
        transfer_recipient_offers(offer, offer.creator);
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
            assert!(dof::exists_<ID>(&offer.id, *vector::borrow(&offer.creator_objects, i)), EInvalidOffer);
        };

        assert!(
            coin::value(dof::borrow<String, Coin<SUI>>(&offer.id, key_creator_coin())) == offer.creator_coin_amount,
            EInvalidOffer
        );
    }

    fun check_recipient_offer(offer: &mut EscrowOffer) {
        let i = 0;
        while (i < vector::length(&offer.recipient_objects)) {
            assert!(dof::exists_<ID>(&offer.id, *vector::borrow(&offer.recipient_objects, i)), EInvalidOffer);
        };

        assert!(
            coin::value(dof::borrow<String, Coin<SUI>>(&offer.id, key_recipient_coin())) == offer.recipient_coin_amount,
            EInvalidOffer
        );
    }

    fun transfer_creator_offers(offer: &mut EscrowOffer, to: address) {
        let i = 0;
        while (i < vector::length(&offer.creator_objects)) {
            if (dof::exists_<ID>(&offer.id, *vector::borrow(&offer.creator_objects, i))) {
                let obj = dof::remove(&mut offer.id, *vector::borrow(&offer.creator_objects, i));
                public_transfer(obj, to);
            }
        };

        if (dof::exists_<String>(&offer.id, key_creator_coin())) {
            let coin = dof::remove<String, Coin<SUI>>(&mut offer.id, key_creator_coin());
            public_transfer(coin, to);
        };
    }

    fun transfer_recipient_offers(offer: &mut EscrowOffer, to: address) {
        let i = 0;
        while (i < vector::length(&offer.recipient_objects)) {
            if (dof::exists_<ID>(&offer.id, *vector::borrow(&offer.recipient_objects, i))) {
                dof::remove(&mut offer.id, *vector::borrow(&offer.recipient_objects, i));
                public_transfer(obj, to);
            }
        };

        if (dof::exists_<String>(&offer.id, key_recipient_coin())) {
            let coin = dof::remove<String, Coin<SUI>>(&mut offer.id, key_recipient_coin());
            public_transfer(coin, to);
        };
    }
}
