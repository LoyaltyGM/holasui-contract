module holasui::utils {
    use sui::balance::{Self, Balance};
    use sui::coin;
    use sui::pay;
    use sui::tx_context::TxContext;
    use sui::coin::Coin;

    friend holasui::loyalty;
    friend holasui::staking;

    // ======== Errors =========

    const EZeroBalance: u64 = 0;
    const EInsufficientPay: u64 = 1;

    // ======== Functions =========

    public(friend) fun withdraw_balance<T>(balance: &mut Balance<T>, ctx: &mut TxContext) {
        let amount = balance::value(balance);
        assert!(amount > 0, EZeroBalance);

        pay::keep<T>(coin::take(balance, amount, ctx), ctx);
    }

    public(friend) fun handle_payment<T>(balance: &mut Balance<T>, coin: Coin<T>, price: u64, ctx: &mut TxContext) {
        assert!(coin::value(&coin) >= price, EInsufficientPay);

        let payment = coin::split(&mut coin, price, ctx);

        coin::put(balance, payment);
        pay::keep(coin, ctx);
    }
}
