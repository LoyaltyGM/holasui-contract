module holasui::escrow {
    use std::string::{utf8, String};
    use std::vector;

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::object_bag::{Self, ObjectBag};
    use sui::package;
    use sui::pay;
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
    const EInsufficientPay: u64 = 6;

    // ======== Types =========
    struct ESCROW has drop {}

    struct EscrowHub has key {
        id: UID,
        fee: u64,
        balance: Balance<SUI>
    }

    /// An object held in escrow
    struct EscrowOffer<phantom T> has key {
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

    fun init(otw: ESCROW, ctx: &mut TxContext) {
        let publisher = package::claim(otw, ctx);

        public_transfer(publisher, sender(ctx));
        share_object(EscrowHub {
            id: object::new(ctx),
            fee: 400000000,
            balance: balance::zero()
        })
    }

    // ======== Creator of Offer functions ========

    public fun create<T>(
        creator_objects: vector<ID>,
        creator_coin_amount: u64,
        recipient: address,
        recipient_objects: vector<ID>,
        recipient_coin_amount: u64,
        ctx: &mut TxContext
    ): EscrowOffer<T> {
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
        offer: EscrowOffer<T>,
        item: T,
        ctx: &mut TxContext
    ): EscrowOffer<T> {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(vector::contains(&offer.creator_objects, &object::id(&item)), EWrongObject);

        object_bag::add<ID, T>(&mut offer.object_bag, object::id(&item), item);

        offer
    }

    public fun update_creator_coin<T>(
        offer: EscrowOffer<T>,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ): EscrowOffer<T> {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(coin::value(&coin) == offer.creator_coin_amount, EWrongCoinAmount);

        object_bag::add<String, Coin<SUI>>(&mut offer.object_bag, key_creator_coin(), coin);

        offer
    }

    public fun share_offer<T>(
        offer: EscrowOffer<T>,
        ctx: &mut TxContext
    ) {
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        check_creator_offer(&mut offer);

        offer.active = true;

        share_object(offer);
    }

    public fun cancel_creator_offer<T: key + store>(
        offer: &mut EscrowOffer<T>,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        transfer_creator_offers(offer, sender(ctx));

        offer.active = false;
    }

    // ======== Recipient of Offer functions ========

    public fun update_recipient_objects<T: key + store>(
        offer: &mut EscrowOffer<T>,
        item: T,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        assert!(vector::contains(&offer.recipient_objects, &object::id(&item)), EWrongObject);

        object_bag::add<ID, T>(&mut offer.object_bag, object::id(&item), item);
    }

    public fun update_recipient_coin<T>(
        offer: &mut EscrowOffer<T>,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        assert!(coin::value(&coin) == offer.recipient_coin_amount, EWrongCoinAmount);

        object_bag::add<String, Coin<SUI>>(&mut offer.object_bag, key_recipient_coin(), coin);
    }

    public fun cancel_recipient_offer<T: key + store>(
        offer: &mut EscrowOffer<T>,
        ctx: &mut TxContext
    ) {
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        transfer_recipient_offers(offer, sender(ctx));
    }

    public fun exchange<T: key + store>(
        offer: &mut EscrowOffer<T>,
        hub: &mut EscrowHub,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        handle_payment(hub, coin, ctx);

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

    fun handle_payment(hub: &mut EscrowHub, coin: Coin<SUI>, ctx: &mut TxContext) {
        assert!(coin::value(&coin) >= hub.fee, EInsufficientPay);

        let payment = coin::split(&mut coin, hub.fee, ctx);

        coin::put(&mut hub.balance, payment);
        pay::keep(coin, ctx);
    }

    fun check_creator_offer<T>(offer: &mut EscrowOffer<T>) {
        let i = 0;
        while (i < vector::length(&offer.creator_objects)) {
            assert!(
                object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.creator_objects, i)),
                EInvalidOffer
            );
        };

        if (offer.creator_coin_amount > 0) {
            assert!(
                coin::value(
                    object_bag::borrow<String, Coin<SUI>>(&offer.object_bag, key_creator_coin())
                ) == offer.creator_coin_amount,
                EInvalidOffer
            );
        }
    }

    fun check_recipient_offer<T>(offer: &mut EscrowOffer<T>) {
        let i = 0;
        while (i < vector::length(&offer.recipient_objects)) {
            assert!(
                object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.recipient_objects, i)),
                EInvalidOffer
            );
        };

        if (offer.recipient_coin_amount > 0) {
            assert!(
                coin::value(
                    object_bag::borrow<String, Coin<SUI>>(&offer.object_bag, key_recipient_coin())
                ) == offer.recipient_coin_amount,
                EInvalidOffer
            );
        }
    }

    fun transfer_creator_offers<T: key + store>(offer: &mut EscrowOffer<T>, to: address) {
        let i = 0;
        while (i < vector::length(&offer.creator_objects)) {
            if (object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.creator_objects, i))) {
                let obj = object_bag::remove<ID, T>(&mut offer.object_bag, *vector::borrow(&offer.creator_objects, i));
                public_transfer(obj, to);
            };
            i = i + 1;
        };

        if (object_bag::contains<String>(&offer.object_bag, key_creator_coin())) {
            let coin = object_bag::remove<String, Coin<SUI>>(&mut offer.object_bag, key_creator_coin());
            public_transfer(coin, to);
        };
    }

    fun transfer_recipient_offers<T: key + store>(offer: &mut EscrowOffer<T>, to: address) {
        let i = 0;
        while (i < vector::length(&offer.recipient_objects)) {
            if (object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.recipient_objects, i))) {
                let obj = object_bag::remove<ID, T>(
                    &mut offer.object_bag,
                    *vector::borrow(&offer.recipient_objects, i)
                );
                public_transfer(obj, to);
            };
            i = i + 1;
        };

        if (object_bag::contains<String>(&offer.object_bag, key_recipient_coin())) {
            let coin = object_bag::remove<String, Coin<SUI>>(&mut offer.object_bag, key_recipient_coin());
            public_transfer(coin, to);
        };
    }
}
