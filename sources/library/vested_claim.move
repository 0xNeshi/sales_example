/// Library-side consumer for `VestedAllocation<S>`.
///
/// `prefunded_sale::claim_into_vesting` returns a `VestedAllocation<S>`
/// hot-potato whose inner `Coin<S>` cannot be extracted outside the
/// library (the carrier has no `drop`/`key`/`store` and its fields are
/// private to `sale.move`). The functions in this module are the only
/// disposal paths. Each one converts the allocation into a
/// `VestingWallet<LinearCurve, S>` that honors the sale's recorded
/// schedule, so the buyer cannot fast-path around vesting by skipping
/// this step.
///
/// ### Curve choice
///
/// v1 ships the linear-with-cliff schedule (`LinearCurve`). The
/// `VestedAllocation<S>` carries the cliff/linear schedule fields the
/// curve consumes (`start_ms`, `cliff_duration_ms`, `duration_ms`).
/// Different wallet shapes (milestone, hybrid, clawback-capable) would
/// be siblings of this module — each one a library-side consumer
/// pinning its own curve witness with its own audit story.
///
/// ### Topologies
///
/// `into_shared_wallet` shares the resulting wallet. Anyone can poke
/// `release`; the wallet always pays out to the recorded beneficiary
/// (the buyer's purchase address). Use when a relay, scheduler, or
/// wallet UI should trigger release without the buyer being online.
///
/// `into_owned_wallet` transfers the wallet to the buyer instead. Only
/// the buyer's transactions can pass `&mut`, so only the buyer can
/// drive release. The vendored wallet has no beneficiary migration, so
/// the original beneficiary is the only address that will ever receive
/// payouts regardless of who holds the wallet object.
///
/// ### Why this lives in the library
///
/// Closing the "buyer calls `prefunded_sale::claim` and skips vesting"
/// bypass requires that the only path producing a `Coin<S>` for a
/// vested sale also enforces the schedule. That has to live next to
/// `prefunded_sale` in the audited library, not in integrator code
/// where a malicious or sloppy integration could expose a coin-leaking
/// shortcut.
module sales_example::vested_claim;

use sales_example::linear_curve::LinearCurve;
use sales_example::sale::{Self, VestedAllocation};
use sales_example::vesting_wallet;

/// Consume a `VestedAllocation<S>` into a fresh shared
/// `VestingWallet<LinearCurve, S>` matching the sale's schedule.
/// Anyone can call `release` on the resulting wallet; payouts always
/// flow to the recorded beneficiary.
public fun into_shared_wallet<S>(
    allocation: VestedAllocation<S>,
    ctx: &mut TxContext,
) {
    let (coin, schedule, beneficiary, _sale_id) = sale::unpack_vested_allocation(allocation);
    let mut wallet = vesting_wallet::new<LinearCurve, S>(
        beneficiary,
        sale::vesting_start_ms(&schedule),
        sale::vesting_cliff_duration_ms(&schedule),
        sale::vesting_duration_ms(&schedule),
        ctx,
    );
    vesting_wallet::deposit(&mut wallet, coin);
    transfer::public_share_object(wallet);
}

/// Consume a `VestedAllocation<S>` into a fresh
/// `VestingWallet<LinearCurve, S>` transferred to the buyer. Only the
/// buyer can pass the resulting wallet by `&mut`, so only the buyer's
/// transactions can call `release`. Payouts still flow to the recorded
/// beneficiary (the same address) and the beneficiary is fixed for the
/// wallet's life.
public fun into_owned_wallet<S>(
    allocation: VestedAllocation<S>,
    ctx: &mut TxContext,
) {
    let (coin, schedule, beneficiary, _sale_id) = sale::unpack_vested_allocation(allocation);
    let mut wallet = vesting_wallet::new<LinearCurve, S>(
        beneficiary,
        sale::vesting_start_ms(&schedule),
        sale::vesting_cliff_duration_ms(&schedule),
        sale::vesting_duration_ms(&schedule),
        ctx,
    );
    vesting_wallet::deposit(&mut wallet, coin);
    transfer::public_transfer(wallet, beneficiary);
}
