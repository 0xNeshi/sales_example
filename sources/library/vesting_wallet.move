// SPDX-License-Identifier: MIT
//
// Vendored from https://github.com/0xNeshi/vesting-wallet
// (sources/library/vesting_wallet.move at the time of import).
// Part of the audited library (Tier 1) — `prefunded_sale`'s
// vested-claim path routes coins exclusively into this wallet
// shape via `vested_claim`, so the wallet's correctness is part
// of the sales standard's audit surface.
//
// Modifications from upstream (documented for review):
//
// 1. Module path renamed `vesting_wallet::vesting_wallet` →
//    `sales_example::vesting_wallet` so this teaching example remains
//    a single-package build.
//
// 2. `migrate_beneficiary` and its `BeneficiaryMigrated` event have
//    been **removed**. The upstream implementation lets the current
//    beneficiary redirect future releases to any address with no
//    issuer / compliance check, which would let a verified buyer
//    point a strategic-round wallet at an unverified address and
//    breaks the "KYC at purchase carries through distribution"
//    invariant. Wallets created by this module are bound to their
//    original beneficiary for life. Integrators that genuinely need
//    beneficiary rotation in a non-compliance-sensitive deployment
//    should either use the upstream wallet directly or wrap this
//    wallet in a compliance-aware container that gates migration.
//
// 3. `new` adds a u128-widened overflow check on
//    `start_ms + duration_ms` so subsequent calls to `end` /
//    `destroy_empty` (which add those fields) cannot overflow. The
//    upstream implementation only checked the `cliff <= duration` and
//    `duration > 0` invariants.

/// A curve-agnostic vesting wallet for a single coin type.
///
/// # The primitive
///
/// One `VestingWallet<C, T>` locks a `Balance<T>` for a single
/// `beneficiary` and tracks how much has already been paid out
/// (`released`). The phantom witness type `C` identifies the curve
/// module that owns the schedule math for this wallet — only that
/// module can mint a `VestedAmount<C>` (via `mint_vested`), and
/// `release` consumes whichever `VestedAmount<C>` the caller supplies.
/// The wallet itself stays unaware of the curve shape; it only enforces
/// release accounting and conservation of funds.
///
/// The sibling `sales_example::linear_curve` module supplies the
/// OZ-compatible linear-with-cliff schedule. Downstream packages can
/// ship their own curves by defining a witness `struct MY_CURVE has
/// drop {}` and a `vested(..): VestedAmount<MY_CURVE>` function that
/// ends in `mint_vested(MY_CURVE{}, amount)` — the wallet's release
/// accounting is reused verbatim through the same `release` entrypoint.
///
/// Schedule fields (`start_ms`, `cliff_ms`, `duration_ms`) are fixed at
/// construction. They are exposed as accessors for curve modules to
/// read; the wallet itself does not interpret them.
///
/// # The flow
///
/// 1. Someone calls `new` (or `create_and_share`) with the schedule and
///    a curve witness type `C`.
/// 2. Anyone funds the wallet via `deposit` (direct) or
///    `receive_and_deposit` (collecting coins that were
///    `public_transfer`'d to the wallet's address). Funds added after
///    `start_ms` retroactively participate in vesting if the curve
///    evaluates against `balance + released` — `linear_curve` does
///    this, and custom curves are encouraged to follow suit.
/// 3. Anyone asks the curve module to mint a `VestedAmount<C>` for the
///    current clock, then passes it to `release`, which sends the
///    not-yet-released portion to the beneficiary. Pre-vested or
///    already-claimed clocks make `release` a silent no-op.
/// 4. Once vesting has ended and the balance is drained, anyone can
///    call `destroy_empty` to reclaim storage rebate.
///
/// Beneficiary is fixed at construction (see header modification #2).
///
/// # Topologies
///
/// `VestingWallet<C, T>` has `key + store`, so the consumer picks the
/// topology after `new` returns:
/// * **Shared** (recommended): `transfer::public_share_object(wallet)`
///   — anyone can poke `release`. `create_and_share` does this in one
///   call.
/// * **Owned** (fast path): `transfer::public_transfer(wallet, addr)`
///   — only the holder can pass the wallet by `&mut` reference, so
///   `deposit` and the other state-changing calls are reachable from
///   the holder's transactions only. Outside parties who want to fund
///   the wallet `public_transfer` their `Coin<T>` directly to the
///   wallet's object address; the holder then claims each one with
///   `receive_and_deposit`, which routes it into the same internal
///   balance as `deposit`. The wallet's beneficiary is fixed at
///   construction, so even if the wallet itself moves between owners
///   the `release` payouts continue to flow to the originally-recorded
///   address.
module sales_example::vesting_wallet;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::transfer::Receiving;

// === Errors ===

const EZeroDuration: u64 = 0;
const EInvalidCliff: u64 = 1;
// Code 2 (EUnauthorized) is reserved — used previously by the now-
// removed `migrate_beneficiary`. Left as a numbering placeholder.
const ENotEnded: u64 = 3;
const ENotEmpty: u64 = 4;
const EScheduleOverflow: u64 = 5;

const U64_MAX: u128 = 18446744073709551615;

// === Types ===

/// The vesting wallet. Schedule fields (`start_ms`, `cliff_ms`,
/// `duration_ms`) are fixed at construction; only `balance` and
/// `released` move over time. Curve modules read `balance + released`
/// as the wallet's "current total" when evaluating the schedule, so
/// deposits made after `start_ms` can participate retroactively in
/// vesting (the shipped `linear_curve` does this).
public struct VestingWallet<phantom C, phantom T> has key, store {
    id: UID,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    released: u64,
    balance: Balance<T>,
}

/// A vested-amount witness produced by curve module `C`. Hot potato:
/// no abilities, so it must be created and consumed in the same PTB.
/// Only the module that defines the witness type `C` can mint one (via
/// `mint_vested`).
public struct VestedAmount<phantom C> {
    amount: u64,
}

// === Events ===
//
// One event per state-changing call (zero events for no-op `release`).
// Phantom `C` / `T` let indexers subscribe per curve and per coin type.

public struct Created<phantom C, phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
}

public struct Deposited<phantom C, phantom T> has copy, drop {
    wallet_id: ID,
    amount: u64,
}

public struct Released<phantom C, phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    amount: u64,
}

public struct Destroyed<phantom C, phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    total_released: u64,
}

// === Creation ===

/// Build a new wallet and return it by value. Returning by value
/// (rather than sharing internally) lets the caller chain creation,
/// funding, and topology selection in a single PTB.
public fun new<C, T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<C, T> {
    assert!(duration_ms > 0, EZeroDuration);
    assert!(cliff_duration_ms <= duration_ms, EInvalidCliff);
    let end_u128 = (start_ms as u128) + (duration_ms as u128);
    assert!(end_u128 <= U64_MAX, EScheduleOverflow);

    let wallet = VestingWallet<C, T> {
        id: object::new(ctx),
        beneficiary,
        start_ms,
        cliff_ms: cliff_duration_ms,
        duration_ms,
        released: 0,
        balance: balance::zero<T>(),
    };

    event::emit(Created<C, T> {
        wallet_id: object::id(&wallet),
        beneficiary,
        start_ms,
        cliff_ms: cliff_duration_ms,
        duration_ms,
    });

    wallet
}

/// Sugar for the common case: build the wallet and share it in one call.
public fun create_and_share<C, T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    let wallet = new<C, T>(beneficiary, start_ms, cliff_duration_ms, duration_ms, ctx);
    transfer::public_share_object(wallet);
}

// === VestedAmount construction ===

/// Mint a `VestedAmount<C>`. Witness-gated: callers must supply a
/// value of type `C`, and only the module that declares `C` (with
/// private constructor) can produce one. The amount is unforgeable in
/// any other module.
public fun mint_vested<C: drop>(_w: C, amount: u64): VestedAmount<C> {
    VestedAmount { amount }
}

/// Read the cumulative vested total recorded in a `VestedAmount<C>`
/// without consuming it.
public fun amount<C>(vested: &VestedAmount<C>): u64 {
    vested.amount
}

// === Funding ===

/// Add a coin to the wallet's balance. Permissionless — the
/// beneficiary's identity is data, not a capability, and anyone may
/// fund.
public fun deposit<C, T>(wallet: &mut VestingWallet<C, T>, coin: Coin<T>) {
    let amount = coin.value();
    wallet.balance.join(coin.into_balance());
    event::emit(Deposited<C, T> { wallet_id: object::id(wallet), amount });
}

/// Claim a coin that an upstream emitter `public_transfer`'d to this
/// wallet's object address, then funnel it through the standard
/// deposit path. Used by emission schedules and payroll robots that
/// don't hold a wallet reference.
public fun receive_and_deposit<C, T>(wallet: &mut VestingWallet<C, T>, receiving: Receiving<Coin<T>>) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    deposit(wallet, coin);
}

// === Release ===

/// Consume a curve-supplied `VestedAmount<C>` and send the
/// not-yet-released portion to the beneficiary. Permissionless: anyone
/// holding wallet and vested-amount references can poke this. The
/// recipient is always read fresh from `wallet.beneficiary` at call
/// time and is fixed for the wallet's life.
///
/// If the curve says nothing new is vested (already drained at this
/// clock), the call still consumes the hot potato but emits no event
/// and transfers no coin.
public fun release<C, T>(
    wallet: &mut VestingWallet<C, T>,
    vested: VestedAmount<C>,
    ctx: &mut TxContext,
) {
    let VestedAmount { amount: vested_total } = vested;
    let releasable = vested_total - wallet.released;
    if (releasable == 0) return;

    wallet.released = wallet.released + releasable;
    let coin = coin::from_balance(wallet.balance.split(releasable), ctx);
    let beneficiary = wallet.beneficiary;
    transfer::public_transfer(coin, beneficiary);

    event::emit(Released<C, T> {
        wallet_id: object::id(wallet),
        beneficiary,
        amount: releasable,
    });
}

// === Cleanup ===

/// Consume a fully-drained, fully-ended wallet to reclaim storage
/// rebate. Permissionless. Coins `public_transfer`'d to a destroyed
/// wallet's address after this call have no path back — pair
/// destruction with halting any upstream emissions that target this
/// wallet.
public fun destroy_empty<C, T>(wallet: VestingWallet<C, T>, clock: &Clock) {
    assert!(clock.timestamp_ms() >= wallet.start_ms + wallet.duration_ms, ENotEnded);
    assert!(wallet.balance.value() == 0, ENotEmpty);

    let wallet_id = object::id(&wallet);
    let beneficiary = wallet.beneficiary;
    let total_released = wallet.released;

    let VestingWallet {
        id,
        beneficiary: _,
        start_ms: _,
        cliff_ms: _,
        duration_ms: _,
        released: _,
        balance,
    } = wallet;
    balance.destroy_zero();
    id.delete();

    event::emit(Destroyed<C, T> { wallet_id, beneficiary, total_released });
}

// === Views ===

/// What `release` would pay out if the supplied `VestedAmount<C>` were
/// consumed now: `vested.amount - wallet.released`. Takes the witness
/// by reference so the caller can still consume it in a subsequent
/// `release`.
public fun available<C, T>(wallet: &VestingWallet<C, T>, vested: &VestedAmount<C>): u64 {
    vested.amount - wallet.released
}

// === Accessors ===

public fun beneficiary<C, T>(wallet: &VestingWallet<C, T>): address { wallet.beneficiary }

public fun start<C, T>(wallet: &VestingWallet<C, T>): u64 { wallet.start_ms }

public fun cliff<C, T>(wallet: &VestingWallet<C, T>): u64 { wallet.cliff_ms }

public fun duration<C, T>(wallet: &VestingWallet<C, T>): u64 { wallet.duration_ms }

public fun end<C, T>(wallet: &VestingWallet<C, T>): u64 { wallet.start_ms + wallet.duration_ms }

public fun released<C, T>(wallet: &VestingWallet<C, T>): u64 { wallet.released }

public fun balance<C, T>(wallet: &VestingWallet<C, T>): u64 { wallet.balance.value() }
