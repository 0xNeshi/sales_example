/// Fixed-rate pricing curve. `allocation = paid * rate` for all
/// timestamps.
///
/// The simplest pricing shape and the one most sales use. The rate is
/// committed at sale init and never changes. `max_rate` on the sale
/// equals the curve's `rate`, so the activation-time inventory backing
/// (`inventory >= hard_cap * max_rate`) gives a tight cover.
///
/// ### Setup
///
/// 1. `prefunded_sale::create_sale<FixedRateCurve, S, P>(max_rate, …)`
///    where `max_rate == rate`.
/// 2. `fixed_rate_curve::init_curve(&mut sale, rate)` — stashes the
///    rate as a dynamic field on the sale.
/// 3. Other Init-phase setup (vault, allowlist, vesting, etc.).
/// 4. `prefunded_sale::share_and_activate(sale, &clock)`.
///
/// ### Purchase
///
/// Buyer threads `quote + purchase` in the same PTB:
///
/// ```move
/// let quote = fixed_rate_curve::quote(&sale, paid);
/// prefunded_sale::purchase(&mut sale, payment, quote, …);
/// ```
///
/// The witness gating ensures only `fixed_rate_curve::quote` can mint
/// a `Quote<FixedRateCurve>`, so a sale parameterized by
/// `FixedRateCurve` cannot be driven by any other pricing logic.
module sales_example::fixed_rate_curve;

use sales_example::prefunded_sale::{Self, PrefundedSale};
use sales_example::sale::{Self, Quote};

use sui::dynamic_field;

// === Errors ===

#[error(code = 0)]
const ERateZero: vector<u8> = "rate must be greater than zero";
#[error(code = 1)]
const ERateExceedsMaxRate: vector<u8> = "rate must be <= sale.max_rate (curve cannot exceed the sale's committed bound)";
#[error(code = 2)]
const ECurveAlreadyConfigured: vector<u8> = "Curve already configured for this sale";
#[error(code = 3)]
const ECurveNotConfigured: vector<u8> = "Curve has not been configured for this sale";
#[error(code = 4)]
const EAllocationOverflow: vector<u8> = "paid * rate overflows u64";

const U64_MAX: u128 = 18446744073709551615;

// === Witness ===

/// One-time witness for this curve. `FixedRateCurve {}` is
/// constructible only inside this module, so only this module can mint
/// a `Quote<FixedRateCurve>`.
public struct FixedRateCurve has drop {}

// === Config (stored as dynamic field on the sale) ===

/// Per-sale config for the fixed-rate curve. Stored as a dynamic
/// field on the sale's UID under `ConfigKey`.
public struct Config has copy, drop, store {
    rate: u64,
}

/// Dynamic-field key. Sale-internal; the type identifies the slot.
public struct ConfigKey has copy, drop, store {}

// === Setup ===

/// Attach a fixed-rate curve config to the sale. Init-phase only.
///
/// Asserts:
/// - `rate > 0`
/// - `rate <= sale.max_rate` (the curve cannot output more tokens
///   per payment unit than the sale committed to). Set `max_rate ==
///   rate` at `create_sale` for the tightest backing.
/// - The sale has no curve config attached yet.
public fun init_curve<S, P>(
    sale: &mut PrefundedSale<FixedRateCurve, S, P>,
    rate: u64,
) {
    assert!(rate > 0, ERateZero);
    assert!(rate <= prefunded_sale::max_rate(sale), ERateExceedsMaxRate);

    let uid = prefunded_sale::uid_mut(sale);
    assert!(!dynamic_field::exists_(uid, ConfigKey {}), ECurveAlreadyConfigured);
    dynamic_field::add(uid, ConfigKey {}, Config { rate });
}

// === Quote ===

/// Mint a `Quote<FixedRateCurve>` for a buyer paying `paid` units.
/// The allocation is `paid * rate`, u128-widened to detect overflow.
public fun quote<S, P>(
    sale: &PrefundedSale<FixedRateCurve, S, P>,
    paid: u64,
): Quote<FixedRateCurve> {
    let rate = current_rate(sale);
    let alloc_128 = (paid as u128) * (rate as u128);
    assert!(alloc_128 <= U64_MAX, EAllocationOverflow);
    sale::mint_quote(FixedRateCurve {}, object::id(sale), paid, alloc_128 as u64)
}

// === Views ===

/// Read the configured rate. Aborts if the curve hasn't been
/// initialised yet.
public fun current_rate<S, P>(sale: &PrefundedSale<FixedRateCurve, S, P>): u64 {
    let uid = prefunded_sale::uid(sale);
    assert!(dynamic_field::exists_(uid, ConfigKey {}), ECurveNotConfigured);
    let cfg: &Config = dynamic_field::borrow(uid, ConfigKey {});
    cfg.rate
}
