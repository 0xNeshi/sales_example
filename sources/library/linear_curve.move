/// OpenZeppelin-compatible linear-with-cliff vesting curve.
///
/// The single curve shipped with this library. Schedule semantics:
///
/// * Pre-start (`now < wallet.start_ms`): zero vested.
/// * Pre-cliff (when `cliff_ms > 0` and `now < start_ms + cliff_ms`):
///   zero vested. At the cliff boundary the value jumps directly to
///   the linear-from-start proportion — the cliff gates the curve, it
///   does not shift it.
/// * Mid-schedule: linear in elapsed time from `start_ms`.
/// * Post-end (`now >= start_ms + duration_ms`): clamped to the
///   wallet's total (`balance + released`).
///
/// The total is re-derived on every call as `balance + released`, so
/// deposits made at `t > start_ms` immediately participate in vesting
/// at the current proportion. This matches the OpenZeppelin
/// `VestingWallet` contract semantics.
///
/// Witness `LinearCurve` is `drop`-only and constructed inside
/// `vested(..)`, so no other module can mint a
/// `VestedAmount<LinearCurve>`. Wallets parameterized by this witness
/// (`VestingWallet<LinearCurve, T>`) accept only quotes minted here.
module sales_example::linear_curve;

use sales_example::vesting_wallet::{Self, VestingWallet, VestedAmount};

use sui::clock::Clock;

/// Witness type for this curve. Field-less with `drop` only; the
/// constructor `LinearCurve {}` is private to this module by Move's
/// usual struct-visibility rules, so no other module can produce one
/// and so cannot mint a `VestedAmount<LinearCurve>`.
public struct LinearCurve has drop {}

/// Mint a `VestedAmount<LinearCurve>` for the wallet at the clock's
/// current timestamp.
public fun vested<T>(wallet: &VestingWallet<LinearCurve, T>, clock: &Clock): VestedAmount<LinearCurve> {
    let amount = vested_amount(wallet, clock);
    vesting_wallet::mint_vested(LinearCurve {}, amount)
}

/// Cumulative vested total at `clock.timestamp_ms()`. View; does not
/// touch wallet state.
public fun vested_amount<T>(wallet: &VestingWallet<LinearCurve, T>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();
    let start_ms = vesting_wallet::start(wallet);
    let cliff_ms = vesting_wallet::cliff(wallet);
    let duration_ms = vesting_wallet::duration(wallet);

    if (now < start_ms) return 0;
    if (cliff_ms > 0 && now < start_ms + cliff_ms) return 0;

    let total = vesting_wallet::balance(wallet) + vesting_wallet::released(wallet);

    if (now >= start_ms + duration_ms) return total;

    let elapsed = (now - start_ms) as u128;
    let vested = ((total as u128) * elapsed) / (duration_ms as u128);
    vested as u64
}

/// Currently-releasable amount: `vested_amount - released`. Computed
/// against the wallet's current release counter; equivalent to
/// `vesting_wallet::available` for a freshly-minted vested amount.
public fun releasable<T>(wallet: &VestingWallet<LinearCurve, T>, clock: &Clock): u64 {
    vested_amount(wallet, clock) - vesting_wallet::released(wallet)
}
