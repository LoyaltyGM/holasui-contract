module holasui::escrow {
    use std::string::{utf8, String};
    use std::vector;

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::dynamic_object_field as dof;
    use sui::event::emit;
    use sui::object::{Self, ID, UID};
    use sui::object_bag::{Self, ObjectBag};
    use sui::package;
    use sui::pay;
    use sui::sui::SUI;
    use sui::transfer::{share_object, public_transfer};
    use sui::tx_context::{TxContext, sender};

    use holasui::staking::AdminCap;

    // ======== Errors =========
    const EWrongOwner: u64 = 0;
    const EWrongRecipient: u64 = 1;
    const EWrongObject: u64 = 2;
    const EWrongCoinAmount: u64 = 3;
    const EInvalidOffer: u64 = 4;
    const EInactiveOffer: u64 = 5;
    const EInsufficientPay: u64 = 6;
    const EZeroBalance: u64 = 7;

    // ======== Types =========
    struct ESCROW has drop {}

    struct EscrowHub has key {
        id: UID,
        fee: u64,
        balance: Balance<SUI>
    }

    /// An object held in escrow
    struct EscrowOffer<phantom T> has key, store {
        id: UID,
        active: bool,
        object_bag: ObjectBag,
        //
        creator: address,
        creator_object_ids: vector<ID>,
        creator_coin_amount: u64,
        //
        recipient: address,
        recipient_object_ids: vector<ID>,
        recipient_coin_amount: u64,
    }

    // ======== Events =========

    struct OfferCreated has copy, drop {
        offer_id: ID,
    }

    struct Exchanged has copy, drop {
        offer_id: ID,
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

    // ======== Admin functions ========

    entry fun set_fee(_: &AdminCap, hub: &mut EscrowHub, fee: u64) {
        hub.fee = fee;
    }

    entry fun withdraw(_: &AdminCap, hub: &mut EscrowHub, ctx: &mut TxContext) {
        let amount = balance::value(&hub.balance);
        assert!(amount > 0, EZeroBalance);

        pay::keep(coin::take(&mut hub.balance, amount, ctx), ctx);
    }


    // ======== Creator of Offer functions ========

    public fun create<T>(
        creator_object_ids: vector<ID>,
        creator_coin_amount: u64,
        recipient: address,
        recipient_object_ids: vector<ID>,
        recipient_coin_amount: u64,
        ctx: &mut TxContext
    ): EscrowOffer<T> {
        assert!(recipient != sender(ctx), EWrongRecipient);
        assert!(vector::length(&creator_object_ids) > 0 || vector::length(&recipient_object_ids) > 0, EInvalidOffer);

        EscrowOffer {
            id: object::new(ctx),
            active: false,
            object_bag: object_bag::new(ctx),
            creator: sender(ctx),
            creator_object_ids,
            creator_coin_amount,
            recipient,
            recipient_object_ids,
            recipient_coin_amount,
        }
    }

    public fun update_creator_objects<T: key + store>(
        offer: EscrowOffer<T>,
        item: T,
        ctx: &mut TxContext
    ): EscrowOffer<T> {
        assert!(!offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(vector::contains(&offer.creator_object_ids, &object::id(&item)), EWrongObject);

        object_bag::add<ID, T>(&mut offer.object_bag, object::id(&item), item);

        offer
    }

    public fun update_creator_coin<T>(
        offer: EscrowOffer<T>,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ): EscrowOffer<T> {
        assert!(!offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        assert!(coin::value(&coin) == offer.creator_coin_amount, EWrongCoinAmount);

        object_bag::add<String, Coin<SUI>>(&mut offer.object_bag, key_creator_coin(), coin);

        offer
    }

    public fun share_offer<T>(
        hub: &mut EscrowHub,
        offer: EscrowOffer<T>,
        ctx: &mut TxContext
    ) {
        assert!(!offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        check_creator_offer(&mut offer);

        offer.active = true;

        emit(OfferCreated {
            offer_id: object::id(&offer)
        });

        dof::add<ID, EscrowOffer<T>>(&mut hub.id, object::id(&offer), offer);
    }

    public fun cancel_creator_offer<T: key + store>(
        hub: &mut EscrowHub,
        offer_id: ID,
        ctx: &mut TxContext
    ) {
        let offer = dof::borrow_mut<ID, EscrowOffer<T>>(&mut hub.id, offer_id);

        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.creator, EWrongOwner);

        transfer_creator_offers(offer, sender(ctx));

        offer.active = false;
    }

    // ======== Recipient of Offer functions ========

    public fun update_recipient_objects<T: key + store>(
        hub: &mut EscrowHub,
        offer_id: ID,
        item: T,
        ctx: &mut TxContext
    ) {
        let offer = dof::borrow_mut<ID, EscrowOffer<T>>(&mut hub.id, offer_id);

        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        assert!(vector::contains(&offer.recipient_object_ids, &object::id(&item)), EWrongObject);

        object_bag::add<ID, T>(&mut offer.object_bag, object::id(&item), item);
    }

    public fun update_recipient_coin<T>(
        hub: &mut EscrowHub,
        offer_id: ID,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let offer = dof::borrow_mut<ID, EscrowOffer<T>>(&mut hub.id, offer_id);

        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        assert!(coin::value(&coin) == offer.recipient_coin_amount, EWrongCoinAmount);

        object_bag::add<String, Coin<SUI>>(&mut offer.object_bag, key_recipient_coin(), coin);
    }

    public fun cancel_recipient_offer<T: key + store>(
        hub: &mut EscrowHub,
        offer_id: ID,
        ctx: &mut TxContext
    ) {
        let offer = dof::borrow_mut<ID, EscrowOffer<T>>(&mut hub.id, offer_id);

        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        transfer_recipient_offers(offer, sender(ctx));
    }

    public fun exchange<T: key + store>(
        hub: &mut EscrowHub,
        offer_id: ID,
        coin: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        handle_payment(hub, coin, ctx);

        let offer = dof::borrow_mut<ID, EscrowOffer<T>>(&mut hub.id, offer_id);

        assert!(offer.active, EInactiveOffer);
        assert!(sender(ctx) == offer.recipient, EWrongRecipient);

        check_creator_offer(offer);
        check_recipient_offer(offer);

        offer.active = false;

        emit(Exchanged {
            offer_id: object::id(offer)
        });

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
        while (i < vector::length(&offer.creator_object_ids)) {
            assert!(
                object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.creator_object_ids, i)),
                EInvalidOffer
            );
            i = i + 1;
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
        while (i < vector::length(&offer.recipient_object_ids)) {
            assert!(
                object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.recipient_object_ids, i)),
                EInvalidOffer
            );
            i = i + 1;
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
        while (i < vector::length(&offer.creator_object_ids)) {
            if (object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.creator_object_ids, i))) {
                let obj = object_bag::remove<ID, T>(
                    &mut offer.object_bag,
                    *vector::borrow(&offer.creator_object_ids, i)
                );
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
        while (i < vector::length(&offer.recipient_object_ids)) {
            if (object_bag::contains<ID>(&offer.object_bag, *vector::borrow(&offer.recipient_object_ids, i))) {
                let obj = object_bag::remove<ID, T>(
                    &mut offer.object_bag,
                    *vector::borrow(&offer.recipient_object_ids, i)
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
