/// Ratcheting pricing curve: price increases linearly in steps over
/// time (equivalently, rate decreases by `step_delta` per elapsed
/// `step_ms` past the sale's `opens_at_ms`, floored at `min_rate`).
///
/// Buyers who purchase earlier get more sale tokens per payment unit;
/// later buyers get fewer. This implements the "presale price ramps
/// up automatically" pattern.
///
/// ### Rate schedule
///
/// Let `t0 = sale.opens_at_ms`. For `now <= t0` the effective rate is
/// `initial_rate`. For `now > t0`:
///
/// ```text
///   steps   = floor((now - t0) / step_ms)
///   rate(t) = max(initial_rate - step_delta * steps, min_rate)
/// ```
///
/// All arithmetic is u128-widened so a runaway schedule cannot wrap.
///
/// ### Setup
///
/// 1. `prefunded_sale::create_sale<RatchetingRateCurve, S, P>(
///        /* max_rate */ initial_rate, …)`
///    — commit `max_rate == initial_rate` (the curve's upper bound).
/// 2. `ratcheting_rate_curve::init_curve(&mut sale, initial_rate,
///        step_ms, step_delta, min_rate)`.
/// 3. Other Init-phase setup, then `share_and_activate`.
///
/// ### Purchase
///
/// ```move
/// let quote = ratcheting_rate_curve::quote(&sale, paid, &clock);
/// prefunded_sale::purchase(&mut sale, payment, quote, …);
/// ```
///
/// The quote locks in the effective rate at the moment of purchase
/// (the curve reads `clock` once); a later finalization or claim does
/// not re-price.
module sales_example::ratcheting_rate_curve;

use sales_example::prefunded_sale::{Self, PrefundedSale};
use sales_example::sale::{Self, Quote};

use sui::clock::Clock;
use sui::dynamic_field;

// === Errors ===

#[error(code = 0)]
const EInitialRateZero: vector<u8> = "initial_rate must be greater than zero";
#[error(code = 1)]
const EInitialRateExceedsMaxRate: vector<u8> = "initial_rate must be <= sale.max_rate";
#[error(code = 2)]
const EStepMsZero: vector<u8> = "step_ms must be greater than zero";
#[error(code = 3)]
const EStepDeltaZero: vector<u8> = "step_delta must be greater than zero";
#[error(code = 4)]
const EMinRateZero: vector<u8> = "min_rate must be greater than zero (a zero rate would let buyers acquire tokens for nothing)";
#[error(code = 5)]
const EMinRateNotBelowInitial: vector<u8> = "min_rate must be strictly less than initial_rate (otherwise the ratchet is a no-op)";
#[error(code = 6)]
const ECurveAlreadyConfigured: vector<u8> = "Curve already configured for this sale";
#[error(code = 7)]
const ECurveNotConfigured: vector<u8> = "Curve has not been configured for this sale";
#[error(code = 8)]
const EAllocationOverflow: vector<u8> = "paid * rate overflows u64";

const U64_MAX: u128 = 18446744073709551615;

// === Witness ===

/// One-time witness for this curve.
public struct RatchetingRateCurve has drop {}

// === Config ===

public struct Config has copy, drop, store {
    initial_rate: u64,
    step_ms: u64,
    step_delta: u64,
    min_rate: u64,
}

public struct ConfigKey has copy, drop, store {}

// === Setup ===

/// Attach a ratcheting-rate curve config to the sale. Init-phase only.
///
/// Asserts:
/// - `initial_rate > 0`
/// - `initial_rate <= sale.max_rate` (curve's max equals
///   `initial_rate`; cannot exceed the sale's committed bound)
/// - `step_ms > 0`, `step_delta > 0`
/// - `min_rate > 0` and `min_rate < initial_rate`
/// - The sale has no curve config attached yet.
public fun init_curve<S, P>(
    sale: &mut PrefundedSale<RatchetingRateCurve, S, P>,
    initial_rate: u64,
    step_ms: u64,
    step_delta: u64,
    min_rate: u64,
) {
    assert!(initial_rate > 0, EInitialRateZero);
    assert!(initial_rate <= prefunded_sale::max_rate(sale), EInitialRateExceedsMaxRate);
    assert!(step_ms > 0, EStepMsZero);
    assert!(step_delta > 0, EStepDeltaZero);
    assert!(min_rate > 0, EMinRateZero);
    assert!(min_rate < initial_rate, EMinRateNotBelowInitial);

    let uid = prefunded_sale::uid_mut(sale);
    assert!(!dynamic_field::exists_(uid, ConfigKey {}), ECurveAlreadyConfigured);
    dynamic_field::add(uid, ConfigKey {}, Config {
        initial_rate, step_ms, step_delta, min_rate,
    });
}

// === Quote ===

/// Mint a `Quote<RatchetingRateCurve>` for a buyer paying `paid`
/// units at the clock's current time. The effective rate is computed
/// from the configured schedule.
public fun quote<S, P>(
    sale: &PrefundedSale<RatchetingRateCurve, S, P>,
    paid: u64,
    clock: &Clock,
): Quote<RatchetingRateCurve> {
    let rate = current_rate(sale, clock);
    let alloc_128 = (paid as u128) * (rate as u128);
    assert!(alloc_128 <= U64_MAX, EAllocationOverflow);
    sale::mint_quote(
        RatchetingRateCurve {},
        object::id(sale),
        paid,
        alloc_128 as u64,
    )
}

// === Views ===

/// Effective rate at the clock's current timestamp.
public fun current_rate<S, P>(
    sale: &PrefundedSale<RatchetingRateCurve, S, P>,
    clock: &Clock,
): u64 {
    let cfg = config(sale);
    let now = clock.timestamp_ms();
    let opens_at = prefunded_sale::opens_at_ms(sale);

    if (now <= opens_at) { return cfg.initial_rate };

    let elapsed = now - opens_at;
    let steps = (elapsed / cfg.step_ms) as u128;
    let dec_128 = steps * (cfg.step_delta as u128);
    let initial_128 = cfg.initial_rate as u128;
    let min_128 = cfg.min_rate as u128;
    if (initial_128 <= min_128 + dec_128) { return cfg.min_rate };
    (initial_128 - dec_128) as u64
}

public fun initial_rate<S, P>(sale: &PrefundedSale<RatchetingRateCurve, S, P>): u64 {
    config(sale).initial_rate
}

public fun step_ms<S, P>(sale: &PrefundedSale<RatchetingRateCurve, S, P>): u64 {
    config(sale).step_ms
}

public fun step_delta<S, P>(sale: &PrefundedSale<RatchetingRateCurve, S, P>): u64 {
    config(sale).step_delta
}

public fun min_rate<S, P>(sale: &PrefundedSale<RatchetingRateCurve, S, P>): u64 {
    config(sale).min_rate
}

// === Internal ===

fun config<S, P>(sale: &PrefundedSale<RatchetingRateCurve, S, P>): &Config {
    let uid = prefunded_sale::uid(sale);
    assert!(dynamic_field::exists_(uid, ConfigKey {}), ECurveNotConfigured);
    dynamic_field::borrow(uid, ConfigKey {})
}
