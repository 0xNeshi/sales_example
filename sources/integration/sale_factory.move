/// Domain-named deploy helpers — the kind of "wire-it-all-up" wrappers
/// an integrator writes once and reuses. These give the integrator team
/// (and their tooling) plain-English entry points like
/// `deploy_strategic_round` instead of asking every caller to compose the
/// raw library primitives.
///
/// **All of this is integrator code.** It lives outside the audit boundary
/// of `openzeppelin_sales`. The library ships building blocks; this
/// module shows what it looks like to assemble them.
///
/// ### Why a vault is always paired (even for public rounds)
///
/// `openzeppelin_sales::prefunded_sale` requires a paired `RefundVault<P>`
/// at activation, regardless of `soft_cap`. The vault is the emergency
/// refund destination — if anything goes wrong (regulatory action,
/// critical bug discovered, compromised infrastructure), the admin can
/// `cancel_emergency` and buyers get their money back. Skipping the
/// vault would leave public rounds with no failure path.
///
/// ### Receipts are non-transferable
///
/// All deployments here inherit the library's non-transferable
/// `Receipt<S>` (`key` only). KYC verification at purchase time
/// automatically extends to distribution because only the original
/// buyer can call `claim` or `refund`. There is no library knob to
/// opt out — partners who want a transferable secondary market for
/// allocations need to either trade post-claim coins or build their
/// own ticket type with compliance enforcement.
module sales_example::sale_factory;

use sales_example::my_token::{Self as my_token, MY_TOKEN};
use sales_example::prefunded_sale;
use sales_example::refund_vault;
use sales_example::simple_kyc::{Self, KycAdminCap, KycModule};
use sui::clock::Clock;
use sui::coin::TreasuryCap;
use sui::sui::SUI;

// === Deploy helpers ===

/// Strategic round: KYC-gated, soft-cap with refund, per-buyer cap,
/// fixed price, receipts bound to buyer.
///
/// Returns `(sale_id, vault_id)` so the caller (test harness, monitoring
/// layer, etc.) can track both shared objects across transactions.
/// The `SaleAdminCap<MY_TOKEN, SUI>` is transferred to `treasury_addr`
/// and is the **emergency-cancel** authority post-share. `finalize` and
/// `cancel_after_close` are permissionless — buyers don't need admin
/// liveness to claim or refund.
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
        rate,
        hard_cap,
        soft_cap,
        opens_at_ms,
        closes_at_ms,
        ctx,
    );
    let sale_id = prefunded_sale::cap_sale_id(&sale_admin_cap);

    // Mint inventory and deposit.
    let inventory = my_token::mint(treasury_cap, inventory_amount, ctx);
    prefunded_sale::deposit_inventory(&mut sale, inventory);

    // Two distinct caps compose here:
    //   - sale-level `per_buyer_cap` (set here) bounds the *cumulative*
    //     total a single buyer can pay across all their purchases to
    //     this sale; enforced inside `purchase` against `contributions[buyer]`.
    //   - KYC's `max_per_entry` (set later via `simple_kyc::verify_buyer`)
    //     bounds *one entry's* payment; the buyer can mint multiple
    //     entries unless this cumulative cap stops them.
    // The strategic-round flow sets both because either alone is
    // insufficient: per-entry doesn't bound the total; per-buyer
    // doesn't bound each individual hit.
    prefunded_sale::set_per_buyer_cap(&mut sale, per_buyer_cap, ctx);

    // Refund vault: create (owned), pair before share, then share.
    let (vault, vault_cap) = refund_vault::new<SUI>(ctx);
    let vault_id = object::id(&vault);
    prefunded_sale::pair_refund_vault(&mut sale, &vault, vault_cap);
    refund_vault::share(vault);

    // Allowlist: enable, route admin into KYC module.
    let allow_admin = prefunded_sale::enable_allowlist(&mut sale, ctx);
    simple_kyc::register_admin(kyc, kyc_cap, allow_admin);

    // Init → Active and share.
    prefunded_sale::share_and_activate(sale, clock);

    transfer::public_transfer(sale_admin_cap, treasury_addr);

    (sale_id, vault_id)
}

/// Public round: open to anyone, no KYC, no soft cap. Still pairs a
/// refund vault so emergency cancellation has a destination.
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

/// Per-buyer-capped public round: like `deploy_public_round` but with a
/// `per_buyer_cap` to limit any single address. Useful for fair-distribution
/// launches.
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
