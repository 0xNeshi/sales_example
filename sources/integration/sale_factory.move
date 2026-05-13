/// Domain-named deploy helpers for the four common fixed-price sale
/// shapes. Integrator-owned, not part of the audited library.
///
/// The helpers consume the library's public API only. They exist so
/// the issuer's tooling has plain-English entry points
/// (`deploy_strategic_round`, etc.) instead of asking every caller
/// to compose the raw primitives.
///
/// ### Which helper to use
///
/// ```text
///                  Need KYC / accreditation?
///                          │
///                ┌─────────┴──────────┐
///                yes                  no
///                │                    │
///                │                    Need per-buyer cap?
///                │                          │
///                │                ┌─────────┴──────────────┐
///                │                yes                      no
///                │                │                        │
///                │       deploy_capped_public_round  deploy_public_round
///                │
///                Need vesting?
///                          │
///              ┌───────────┴────────────────────┐
///              yes                              no
///              │                                │
///   deploy_strategic_round_vested      deploy_strategic_round
/// ```
///
/// Each helper pairs a `RefundVault<P>` even when `soft_cap == 0`:
/// the library requires a vault at activation regardless, so
/// `cancel_emergency` always has a refund destination.
///
/// The vested variant additionally calls
/// `prefunded_sale::set_vesting_schedule` during Init, which switches
/// the sale into vesting-only redemption: the plain `claim` path
/// aborts and buyers must redeem through
/// `claim_into_vesting → vested_claim::into_*`. See the strategic
/// round documentation below for details.
///
/// ### What this library does not do
///
/// All helpers produce **fixed-price** sales. None of them
/// implements:
/// - bonding-curve / LBP price discovery,
/// - Dutch / English / sealed-bid auctions,
/// - fair-launch token-mint patterns (no pre-mine, public-from-t=0
///   bonding curve, etc).
///
/// Reach for a different primitive if those are what you need.
module sales_example::sale_factory;

use sales_example::prefunded_sale;
use sales_example::refund_vault;
use sales_example::my_token::{Self as my_token, MY_TOKEN};
use sales_example::simple_kyc::{Self, KycAdminCap, KycModule};

use sui::clock::Clock;
use sui::coin::TreasuryCap;
use sui::sui::SUI;

// === Strategic round ===

/// KYC-gated, soft-cap with refund, per-buyer cap. Standard shape
/// for a compliance-leaning raise (private round, strategic round,
/// regulated public offering). Immediate distribution at claim time
/// — for the vesting-attached variant, see
/// `deploy_strategic_round_vested`.
///
/// Configuration:
/// - `rate`, `hard_cap`, `soft_cap`, `opens_at_ms`, `closes_at_ms`
///   — fixed-price sale parameters; soft cap > 0 enables refund-on-miss.
/// - `inventory_amount` — minted from `treasury_cap` and deposited.
///   Must cover `hard_cap * rate` (the library asserts at activation).
/// - `per_buyer_cap` — cumulative payment cap per buyer to this sale.
///   Without this, a single verified buyer could mint multiple
///   allowlist entries and buy the entire allocation. This helper
///   sets it because either cap alone is insufficient (see
///   `simple_kyc` module docs).
///
/// Returns `(sale_id, vault_id)`. `SaleAdminCap<MY_TOKEN, SUI>` is
/// transferred to `treasury_addr`. The cap controls only
/// `cancel_emergency` and the proceeds/inventory withdrawals; buyer
/// claims and refunds, and the permissionless close paths, never
/// need it.
public fun deploy_strategic_round(
    treasury_cap: &mut TreasuryCap<MY_TOKEN>,
    kyc: &mut KycModule,
    kyc_cap: &KycAdminCap,
    treasury_addr: address,
    rate: u64,
    inventory_amount: u64,
    hard_cap: u64,
    soft_cap: u64,
    per_buyer_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<MY_TOKEN, SUI>(
        rate, hard_cap, soft_cap, opens_at_ms, closes_at_ms, ctx,
    );
    let sale_id = prefunded_sale::cap_sale_id(&sale_admin_cap);

    // Mint inventory and deposit.
    let inventory = my_token::mint(treasury_cap, inventory_amount, ctx);
    prefunded_sale::deposit_inventory(&mut sale, inventory);

    // Two caps compose:
    //   - sale-level per_buyer_cap (set here) bounds the cumulative
    //     total a single buyer can pay to this sale, enforced inside
    //     `purchase` against `contributions[buyer]`.
    //   - KYC's max_per_entry (set later via simple_kyc::verify_buyer)
    //     bounds one entry's payment; the buyer can mint multiple
    //     entries unless this cumulative cap stops them.
    // Neither alone is sufficient for a strategic round.
    prefunded_sale::set_per_buyer_cap(&mut sale, per_buyer_cap, ctx);

    // Refund vault: create owned, pair before share, share after.
    let (vault, vault_cap) = refund_vault::new<SUI>(ctx);
    let vault_id = object::id(&vault);
    prefunded_sale::pair_refund_vault(&mut sale, &vault, vault_cap);
    refund_vault::share(vault);

    // Allowlist: enable, route admin into KYC module.
    let allow_admin = prefunded_sale::enable_allowlist(&mut sale, ctx);
    simple_kyc::register_admin(kyc, kyc_cap, allow_admin);

    // Activate.
    prefunded_sale::share_and_activate(sale, clock);

    transfer::public_transfer(sale_admin_cap, treasury_addr);

    (sale_id, vault_id)
}

// === Strategic round (vested) ===

/// Same as `deploy_strategic_round`, plus an issuer-defined vesting
/// policy attached to the sale at construction. Once the sale is
/// activated, `prefunded_sale::claim` aborts; the only redemption
/// path is `prefunded_sale::claim_into_vesting` →
/// `vested_claim::into_*`. The buyer cannot supply, override, or
/// shorten the schedule.
///
/// Extra parameters:
/// - `vesting_start_ms`, `vesting_cliff_duration_ms`,
///   `vesting_duration_ms` — schedule, in milliseconds. See
///   `prefunded_sale::set_vesting_schedule` for validation rules.
public fun deploy_strategic_round_vested(
    treasury_cap: &mut TreasuryCap<MY_TOKEN>,
    kyc: &mut KycModule,
    kyc_cap: &KycAdminCap,
    treasury_addr: address,
    rate: u64,
    inventory_amount: u64,
    hard_cap: u64,
    soft_cap: u64,
    per_buyer_cap: u64,
    vesting_start_ms: u64,
    vesting_cliff_duration_ms: u64,
    vesting_duration_ms: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<MY_TOKEN, SUI>(
        rate, hard_cap, soft_cap, opens_at_ms, closes_at_ms, ctx,
    );
    let sale_id = prefunded_sale::cap_sale_id(&sale_admin_cap);

    let inventory = my_token::mint(treasury_cap, inventory_amount, ctx);
    prefunded_sale::deposit_inventory(&mut sale, inventory);

    prefunded_sale::set_per_buyer_cap(&mut sale, per_buyer_cap, ctx);

    // Vesting policy: sale-defined, library-enforced. Once attached,
    // `prefunded_sale::claim` aborts and buyers must go through
    // `claim_into_vesting` + `vested_claim::into_*`.
    prefunded_sale::set_vesting_schedule(
        &mut sale,
        vesting_start_ms,
        vesting_cliff_duration_ms,
        vesting_duration_ms,
    );

    let (vault, vault_cap) = refund_vault::new<SUI>(ctx);
    let vault_id = object::id(&vault);
    prefunded_sale::pair_refund_vault(&mut sale, &vault, vault_cap);
    refund_vault::share(vault);

    let allow_admin = prefunded_sale::enable_allowlist(&mut sale, ctx);
    simple_kyc::register_admin(kyc, kyc_cap, allow_admin);

    prefunded_sale::share_and_activate(sale, clock);

    transfer::public_transfer(sale_admin_cap, treasury_addr);

    (sale_id, vault_id)
}

// === Public round ===

/// Open to anyone, no KYC, no soft cap, no per-buyer cap. FCFS up
/// to `hard_cap`. A refund vault is still paired so emergency
/// cancellation has a destination.
///
/// Use for public sales where the issuer doesn't care which
/// addresses purchase or how much each one buys (a single buyer
/// could acquire the entire allocation up to `hard_cap`).
public fun deploy_public_round(
    treasury_cap: &mut TreasuryCap<MY_TOKEN>,
    treasury_addr: address,
    rate: u64,
    inventory_amount: u64,
    hard_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<MY_TOKEN, SUI>(
        rate,
        hard_cap,
        /* soft_cap */ 0,
        opens_at_ms,
        closes_at_ms,
        ctx,
    );
    let sale_id = prefunded_sale::cap_sale_id(&sale_admin_cap);

    let inventory = my_token::mint(treasury_cap, inventory_amount, ctx);
    prefunded_sale::deposit_inventory(&mut sale, inventory);

    let (vault, vault_cap) = refund_vault::new<SUI>(ctx);
    let vault_id = object::id(&vault);
    prefunded_sale::pair_refund_vault(&mut sale, &vault, vault_cap);
    refund_vault::share(vault);

    prefunded_sale::share_and_activate(sale, clock);
    transfer::public_transfer(sale_admin_cap, treasury_addr);

    (sale_id, vault_id)
}

// === Capped public round ===

/// Open to anyone, no KYC, but with a cumulative per-buyer cap. The
/// per-buyer cap is enforced inside `purchase` against the running
/// `contributions[buyer]` total: once a buyer's total payments to
/// this sale reach `per_buyer_cap`, further purchases by the same
/// address abort.
///
/// Use when the issuer wants to bound single-address concentration
/// (anti-whale) without imposing identity verification.
public fun deploy_capped_public_round(
    treasury_cap: &mut TreasuryCap<MY_TOKEN>,
    treasury_addr: address,
    rate: u64,
    inventory_amount: u64,
    hard_cap: u64,
    per_buyer_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (ID, ID) {
    let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<MY_TOKEN, SUI>(
        rate,
        hard_cap,
        /* soft_cap */ 0,
        opens_at_ms,
        closes_at_ms,
        ctx,
    );
    let sale_id = prefunded_sale::cap_sale_id(&sale_admin_cap);

    let inventory = my_token::mint(treasury_cap, inventory_amount, ctx);
    prefunded_sale::deposit_inventory(&mut sale, inventory);

    prefunded_sale::set_per_buyer_cap(&mut sale, per_buyer_cap, ctx);

    let (vault, vault_cap) = refund_vault::new<SUI>(ctx);
    let vault_id = object::id(&vault);
    prefunded_sale::pair_refund_vault(&mut sale, &vault, vault_cap);
    refund_vault::share(vault);

    prefunded_sale::share_and_activate(sale, clock);
    transfer::public_transfer(sale_admin_cap, treasury_addr);

    (sale_id, vault_id)
}
