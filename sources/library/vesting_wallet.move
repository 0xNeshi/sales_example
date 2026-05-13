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
//    `start_ms + duration_ms` so subsequent calls to `vested_amount`,
//    `end`, and `destroy_empty` (which add those fields) cannot
//    overflow. The upstream implementation only checked the
//    `cliff <= duration` and `duration > 0` invariants.

/// A linear vesting wallet for a single coin type.
///
/// # The schedule
///
/// One wallet locks a `Balance<T>` for a single `beneficiary` and releases it
/// linearly between `start_ms` and `start_ms + duration_ms`. An optional cliff
/// (`cliff_ms`) gates releases until `start_ms + cliff_ms` — at the cliff
/// boundary, the vested amount jumps from zero straight to the linear-from-start
/// proportion (`total * cliff_ms / duration_ms`). The curve itself is not
/// shifted by the cliff; the cliff only delays when releases become reachable.
///
/// # The flow
///
/// 1. Someone calls `new` (or `create_and_share`) with the schedule.
/// 2. Anyone funds the wallet via `deposit` (direct) or `receive_and_deposit`
///    (collecting coins that were `public_transfer`'d to the wallet's address).
///    Funds added after `start_ms` retroactively participate in vesting — the
///    curve is always evaluated against `balance + released`, never a snapshot.
/// 3. Anyone can call `release` to send the currently-vested amount to the
///    beneficiary. Pre-cliff or already-claimed calls are silent no-ops.
/// 4. Once vesting has ended and the balance is drained, anyone can call
///    `destroy_empty` to reclaim storage rebate.
///
/// Beneficiary is fixed at construction (see header modification #2).
///
/// # Topologies
///
/// `VestingWallet<T>` has `key + store`, so the consumer picks the topology
/// after `new` returns:
/// * **Shared** (recommended): `transfer::public_share_object(wallet)` —
///   anyone can poke `release`. `create_and_share` does this in one call.
/// * **Owned** (fast path): `transfer::public_transfer(wallet, addr)` — only
///   the holder can pass the wallet by `&mut` reference, so `deposit` and the
///   other state-changing calls are reachable from the holder's transactions
///   only. Outside parties who want to fund the wallet `public_transfer` their
///   `Coin<T>` directly to the wallet's object address; the holder then claims
///   each one with `receive_and_deposit`, which routes it into the same
///   internal balance as `deposit`. The wallet's beneficiary is fixed at
///   construction, so even if the wallet itself moves between owners the
///   `release` payouts continue to flow to the originally-recorded address.
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

/// The vesting wallet. Schedule fields (`start_ms`, `cliff_ms`, `duration_ms`)
/// are fixed at construction; only `balance` and `released` move over time.
/// Their sum is the wallet's "current total" and feeds every view computation.
public struct VestingWallet<phantom T> has key, store {
    id: UID,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
    released: u64,
    balance: Balance<T>,
}

// === Events ===
//
// One event per state-changing call (zero events for no-op `release`).
// Phantom `T` lets indexers subscribe per coin type.

public struct Created<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    start_ms: u64,
    cliff_ms: u64,
    duration_ms: u64,
}

public struct Deposited<phantom T> has copy, drop {
    wallet_id: ID,
    amount: u64,
}

public struct Released<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    amount: u64,
}

public struct Destroyed<phantom T> has copy, drop {
    wallet_id: ID,
    beneficiary: address,
    total_released: u64,
}

// === Creation ===

/// Build a new wallet and return it by value. Returning by value (rather than
/// sharing internally) lets the caller chain creation, funding, and topology
/// selection in a single PTB.
public fun new<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
): VestingWallet<T> {
    assert!(duration_ms > 0, EZeroDuration);
    assert!(cliff_duration_ms <= duration_ms, EInvalidCliff);
    // u128-widened guard: `start + duration` is computed unchecked in
    // `vested_amount` / `end` / `destroy_empty`. Reject schedules
    // whose end would not fit in `u64` so those callsites cannot
    // overflow at runtime.
    let end_u128 = (start_ms as u128) + (duration_ms as u128);
    assert!(end_u128 <= U64_MAX, EScheduleOverflow);

    let wallet = VestingWallet<T> {
        id: object::new(ctx),
        beneficiary,
        start_ms,
        cliff_ms: cliff_duration_ms,
        duration_ms,
        released: 0,
        balance: balance::zero<T>(),
    };

    event::emit(Created<T> {
        wallet_id: object::id(&wallet),
        beneficiary,
        start_ms,
        cliff_ms: cliff_duration_ms,
        duration_ms,
    });

    wallet
}

/// Sugar for the common case: build the wallet and share it in one call.
public fun create_and_share<T>(
    beneficiary: address,
    start_ms: u64,
    cliff_duration_ms: u64,
    duration_ms: u64,
    ctx: &mut TxContext,
) {
    let wallet = new<T>(beneficiary, start_ms, cliff_duration_ms, duration_ms, ctx);
    transfer::public_share_object(wallet);
}

// === Funding ===

/// Add a coin to the wallet's balance. Permissionless — the beneficiary's
/// identity is data, not a capability, and anyone may fund.
public fun deposit<T>(wallet: &mut VestingWallet<T>, coin: Coin<T>) {
    let amount = coin.value();
    wallet.balance.join(coin.into_balance());
    event::emit(Deposited<T> { wallet_id: object::id(wallet), amount });
}

/// Claim a coin that an upstream emitter `public_transfer`'d to this wallet's
/// object address, then funnel it through the standard deposit path. Used by
/// emission schedules and payroll robots that don't hold a wallet reference.
public fun receive_and_deposit<T>(wallet: &mut VestingWallet<T>, receiving: Receiving<Coin<T>>) {
    let coin = transfer::public_receive(&mut wallet.id, receiving);
    deposit(wallet, coin);
}

// === Release ===

/// Send whatever is currently vested-but-not-yet-released to the beneficiary.
/// Permissionless: anyone with a wallet reference can poke this. The recipient
/// is always `wallet.beneficiary`, which this module pins at construction —
/// the beneficiary cannot be rotated after `new`, so every release flows to
/// the same address for the lifetime of the wallet.
///
/// If nothing is releasable (pre-cliff, or already drained at this clock), the
/// call returns silently without emitting an event or minting a zero-value
/// coin. Callers can poll-then-poke without pre-checking.
public fun release<T>(wallet: &mut VestingWallet<T>, clock: &Clock, ctx: &mut TxContext) {
    let amount = releasable(wallet, clock);
    if (amount == 0) return;

    wallet.released = wallet.released + amount;
    let coin = coin::from_balance(wallet.balance.split(amount), ctx);
    let beneficiary = wallet.beneficiary;
    transfer::public_transfer(coin, beneficiary);

    event::emit(Released<T> {
        wallet_id: object::id(wallet),
        beneficiary,
        amount,
    });
}

// === Cleanup ===

/// Consume a fully-drained, fully-ended wallet to reclaim storage rebate.
/// Permissionless. Coins `public_transfer`'d to a destroyed wallet's address
/// after this call have no path back — pair destruction with halting any
/// upstream emissions that target this wallet.
public fun destroy_empty<T>(wallet: VestingWallet<T>, clock: &Clock) {
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

    event::emit(Destroyed<T> { wallet_id, beneficiary, total_released });
}

// === Views ===

/// The schedule curve evaluated at `clock.timestamp_ms()`.
///
/// * Pre-start: zero.
/// * Pre-cliff (when a cliff is configured): zero. At the cliff boundary the
///   value jumps directly to the linear-from-start proportion — the cliff
///   gates the curve, it does not shift it.
/// * Mid-schedule: linear in elapsed time.
/// * Post-end: clamped to the wallet's total (`balance + released`).
///
/// The total is re-derived on every call, so deposits made at `t > start_ms`
/// immediately participate in vesting at the current proportion.
public fun vested_amount<T>(wallet: &VestingWallet<T>, clock: &Clock): u64 {
    let now = clock.timestamp_ms();

    if (now < wallet.start_ms) return 0;
    if (wallet.cliff_ms > 0 && now < wallet.start_ms + wallet.cliff_ms) return 0;

    let total = wallet.balance.value() + wallet.released;

    if (now >= wallet.start_ms + wallet.duration_ms) return total;

    let elapsed = (now - wallet.start_ms) as u128;
    let vested = ((total as u128) * elapsed) / (wallet.duration_ms as u128);
    vested as u64
}

/// What `release` would pay out if called now.
public fun releasable<T>(wallet: &VestingWallet<T>, clock: &Clock): u64 {
    vested_amount(wallet, clock) - wallet.released
}

// === Accessors ===

public fun beneficiary<T>(wallet: &VestingWallet<T>): address { wallet.beneficiary }

public fun start<T>(wallet: &VestingWallet<T>): u64 { wallet.start_ms }

public fun cliff<T>(wallet: &VestingWallet<T>): u64 { wallet.cliff_ms }

public fun duration<T>(wallet: &VestingWallet<T>): u64 { wallet.duration_ms }

public fun end<T>(wallet: &VestingWallet<T>): u64 { wallet.start_ms + wallet.duration_ms }

public fun released<T>(wallet: &VestingWallet<T>): u64 { wallet.released }

public fun balance<T>(wallet: &VestingWallet<T>): u64 { wallet.balance.value() }
