/// `PrefundedSale<S, P>` — the v1 sale flavor.
///
/// Issuer pre-mints (or pre-acquires) the sale tokens, deposits them into
/// the sale during Init, and the sale draws from that fixed inventory at
/// claim time. The sale **never** holds a `TreasuryCap`. This eliminates
/// the largest safety concern flagged in research (cap-in-contract risk)
/// and is the right v1 default. v2's `MintingSale<S, P>` will land as a
/// parallel top-level type for the mint-on-claim use case, sharing the
/// same `Receipt<S>` and `Phase`.
///
/// ### Lifecycle
///
/// ```
///   create_sale ──→ deposit_inventory ──┐
///                   set_per_buyer_cap   │
///                   pair_refund_vault   ├─→ share_and_activate ──→ purchase (×N) ──┬─→ finalize ──→ claim, withdraw_proceeds, withdraw_unsold
///                   enable_allowlist    │                                          │   (permissionless when
///                                       │                                          │    raised >= soft_cap and
///                                       │  (Init)                                  │    (now > close OR hard cap reached))
///                                       │                                          │
///                                       │                                          ├─→ cancel_after_close ──→ refund, withdraw_unsold
///                                       │                                          │   (permissionless when
///                                       │                                          │    now > close AND raised < soft_cap)
///                                       │                                          │
///                                       │                                          └─→ cancel_emergency ──→ refund, withdraw_unsold
///                                       │                                              (admin during Active when
///                                       │                                               raised < soft_cap AND raised < hard_cap)
///                                       │                                                                              (Cancelled)
///                                       └─ during Init, holding the sale value
///                                          by &mut IS the authority
/// ```
///
/// ### Integrator caveats (must-read)
///
/// 1. **Setup happens before `share_and_activate`**, while the sale is
///    still owned. After share, no more setup is possible — it's a
///    one-way phase transition.
///
/// 2. **`SaleAdminCap<S, P>` is the post-share emergency authority.**
///    Wrap it in your RBAC scheme, multisig, or governance object.
///    Closing flows (`finalize`, `cancel_after_close`) are permissionless
///    once their conditions are met, so losing the cap does **not** brick
///    buyer claims/refunds — it only removes the emergency-cancel power
///    and the proceeds/inventory withdrawal authority (which keeps funds
///    pinned in the sale forever, but does not strand any buyer).
///
/// 3. **Every sale requires a paired `RefundVault<P>`.** Even sales with
///    `soft_cap == 0` need a vault, so emergency cancel always has a
///    refund destination. Pair one *before* activating.
///
/// 4. **Receipts are non-fungible AND non-transferable.** `Receipt<S>`
///    has `key` only (no `store`), so it cannot be transferred between
///    addresses by anyone except this library — and the library only
///    transfers it once, at purchase time, to the buyer. Claim and
///    refund always assert `ctx.sender() == receipt.buyer`. A buyer
///    with multiple purchases holds multiple receipts; `claim_all`
///    batches them. There is no opt-out for secondary markets. Because
///    receipts lack `store`, they cannot be wrapped as a field inside
///    another struct either — partners who want transferable allocations
///    must either trade the resulting `Coin<S>` after `claim` (or
///    `Coin<P>` after `refund`), or build their own ticket type with
///    compliance enforcement on every transfer.
///
/// 5. **Stale receipts pin both inventory and refund funds.** Buyer-
///    protective by design in v1; no grace-period sweep.
///    - In **Finalized**: an unclaimed receipt keeps its `allocation`
///      pinned inside `sale.inventory`. Admin's
///      `withdraw_unsold_inventory` only releases the *unallocated*
///      portion (`inventory - total_allocated`).
///    - In **Cancelled**: an unrefunded receipt keeps its `paid` amount
///      pinned inside the vault's `locked` balance, *and* its
///      `allocation` still counts toward `total_allocated` (decrement
///      happens only inside `refund`). The vault remains in `Refunding`
///      indefinitely; `withdraw_all` requires `Closed`, which only
///      `finalize` reaches — and `finalize` is not callable from
///      `Cancelled`. So both the buyer's sale tokens AND their payment
///      stay locked until they refund.
///    The chosen trade-off favours buyers: they can always come back
///    and reclaim what they paid. An admin sweep would weaken that.
///
/// 6. **Pricing constraint.** `hard_cap` must be > 0. Inventory at
///    activation must cover the maximum possible raise (`hard_cap * rate`).
///    Sold-out and hard-cap-reached therefore coincide.
module sales_example::prefunded_sale;

use sales_example::allowlist::{Self, AllowEntry, AllowlistAdmin};
use sales_example::refund_vault::{Self, RefundVault, RefundVaultCap};
use sales_example::sale::{Self, Phase, Receipt};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};

// === Errors ===

// Phase guards
#[error(code = 0)]
const ENotInit: vector<u8> = "Sale must be in Init phase";
#[error(code = 1)]
const ENotActive: vector<u8> = "Sale must be in Active phase";
#[error(code = 2)]
const ENotFinalized: vector<u8> = "Sale must be in Finalized phase";
#[error(code = 3)]
const ENotCancelled: vector<u8> = "Sale must be in Cancelled phase";
#[error(code = 4)]
const ENotTerminal: vector<u8> = "Sale must be in a terminal phase (Finalized or Cancelled)";

// Auth
#[error(code = 10)]
const EWrongAdminCap: vector<u8> = "Admin cap does not match this sale";
#[error(code = 11)]
const EBuyerOnly: vector<u8> =
    "Receipt is bound to its buyer; transaction sender must equal receipt.buyer";
#[error(code = 12)]
const EEmergencyCancelAfterClose: vector<u8> =
    "cancel_emergency can only be called during the active window; use cancel_after_close instead";

// Time
#[error(code = 20)]
const EInvalidTimeRange: vector<u8> = "opens_at_ms must be strictly less than closes_at_ms";
#[error(code = 21)]
const ESaleWindowClosed: vector<u8> = "Purchase outside [opens_at_ms, closes_at_ms]";
#[error(code = 22)]
const ESaleWindowStillOpen: vector<u8> =
    "Cannot close: window still open and hard cap not yet reached";
#[error(code = 23)]
const EActivationAfterClose: vector<u8> = "Cannot activate: closes_at_ms is already in the past";

// Pricing & accounting
#[error(code = 30)]
const ERateZero: vector<u8> = "rate must be greater than zero";
#[error(code = 31)]
const EHardCapZero: vector<u8> = "hard_cap must be greater than zero";
#[error(code = 32)]
const EInvalidCapsOrdering: vector<u8> = "soft_cap must be <= hard_cap";
#[error(code = 33)]
const EZeroPayment: vector<u8> = "Payment must be greater than zero";
#[error(code = 34)]
const EAllocationOverflow: vector<u8> = "payment * rate overflows u64";
#[error(code = 35)]
const ERaisedOverflow: vector<u8> = "raised + payment overflows u64";
#[error(code = 36)]
const EContributionOverflow: vector<u8> = "buyer contribution + payment overflows u64";
#[error(code = 37)]
const EHardCapExceeded: vector<u8> = "Purchase would exceed hard_cap";
#[error(code = 38)]
const EInventoryOverflowAtActivate: vector<u8> =
    "hard_cap * rate overflows u64; cannot guarantee inventory backing";
#[error(code = 39)]
const EInsufficientInventoryAtActivate: vector<u8> =
    "Inventory at activation does not cover hard_cap * rate";

// Caps
#[error(code = 40)]
const EPerBuyerCapExceeded: vector<u8> = "Purchase exceeds per-buyer cap";
#[error(code = 41)]
const EPerEntryCapExceeded: vector<u8> = "Purchase exceeds AllowEntry max_amount";
#[error(code = 42)]
const ESoftCapNotMet: vector<u8> = "Cannot finalize: raised < soft_cap";
#[error(code = 43)]
const ESoftCapMet: vector<u8> = "Cannot cancel: soft_cap already met or no soft_cap configured";
#[error(code = 44)]
const ESaleAlreadyComplete: vector<u8> =
    "Cannot cancel: hard_cap already reached, sale must finalize";

// Allowlist coupling
#[error(code = 50)]
const EAllowlistRequired: vector<u8> = "Sale requires AllowEntry but none provided";
#[error(code = 51)]
const EAllowlistNotRequired: vector<u8> = "Sale does not require AllowEntry but one was provided";
#[error(code = 52)]
const EAllowlistAlreadyEnabled: vector<u8> = "Allowlist already enabled for this sale";

// Vault coupling
#[error(code = 60)]
const EVaultAlreadyPaired: vector<u8> = "Refund vault already paired";
#[error(code = 61)]
const EVaultRequiredForActivate: vector<u8> = "Activation requires a paired refund vault";
#[error(code = 62)]
const EWrongVault: vector<u8> = "Provided vault does not match the one paired with this sale";
#[error(code = 63)]
const EVaultNotActive: vector<u8> = "Refund vault must be in Active state when paired";
#[error(code = 64)]
const EVaultNotEmpty: vector<u8> =
    "Refund vault must be empty (value == 0) when paired; pre-existing funds would be stranded after finalize/cancel";

// Receipts
#[error(code = 70)]
const EReceiptSaleMismatch: vector<u8> = "Receipt does not belong to this sale";

// Per-buyer cap configuration
#[error(code = 80)]
const EPerBuyerCapAlreadySet: vector<u8> = "Per-buyer cap already configured";
#[error(code = 81)]
const EPerBuyerCapZero: vector<u8> =
    "Per-buyer cap must be greater than zero (a zero cap blocks every buyer)";

// === Types ===

public struct PrefundedSale<phantom S, phantom P> has key {
    id: UID,
    // Inventory & accounting
    /// Pre-funded sale tokens. Deposited during Init, drawn down on claim.
    inventory: Balance<S>,
    /// Tokens allocated to outstanding receipts.
    /// Invariant: `inventory.value() >= total_allocated`. The unsold
    /// remainder, available to admin, is `inventory.value() - total_allocated`.
    total_allocated: u64,
    /// Accumulated payments. Drained to admin on `withdraw_proceeds`
    /// (Finalized) or to vault on cancel (Cancelled).
    proceeds: Balance<P>,
    // Pricing
    /// Sale tokens (smallest units) per 1 payment-coin smallest unit.
    rate: u64,
    // Caps
    hard_cap: u64, // strictly > 0 (enforced at create_sale)
    soft_cap: u64, // 0 = no soft cap, else <= hard_cap
    raised: u64,
    // Time
    opens_at_ms: u64,
    closes_at_ms: u64,
    // Lifecycle
    phase: Phase,
    // Hooks
    requires_allowlist: bool,
    /// Paired vault ID. Always Some after `pair_refund_vault`.
    refund_vault_id: Option<ID>,
    /// Wrapped controller. Sale's lifecycle drives the vault state.
    refund_vault_cap: Option<RefundVaultCap<P>>,
    // Optional per-buyer cap (lazy table)
    per_buyer_cap: Option<u64>,
    contributions: Option<Table<address, u64>>,
}

public struct SaleAdminCap<phantom S, phantom P> has key, store {
    id: UID,
    sale_id: ID,
}

// === Events ===

public struct SaleCreated<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
}

public struct InventoryDeposited<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    amount: u64,
    inventory_after: u64,
}

public struct PerBuyerCapSet<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    cap: u64,
}

public struct RefundVaultPaired<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    vault_id: ID,
}

public struct AllowlistEnabled<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    allowlist_admin_id: ID,
}

public struct SaleActivated<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    activated_at_ms: u64,
}

public struct Purchased<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    paid: u64,
    allocation: u64,
    raised_after: u64,
    purchased_at_ms: u64,
}

public struct SaleFinalized<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    raised: u64,
    closed_at_ms: u64,
}

public enum CancelReason has copy, drop, store {
    SoftCapMissed,
    AdminEmergency,
}

public struct SaleCancelled<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    raised: u64,
    reason: CancelReason,
    closed_at_ms: u64,
}

public struct Claimed<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

public struct Refunded<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    buyer: address,
    receipt_id: ID,
    amount: u64,
}

public struct ProceedsWithdrawn<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    amount: u64,
}

public struct InventoryWithdrawn<phantom S, phantom P> has copy, drop {
    sale_id: ID,
    amount: u64,
}

// === Internal helpers ===

const U64_MAX: u128 = 18446744073709551615;

fun assert_admin<S, P>(sale: &PrefundedSale<S, P>, cap: &SaleAdminCap<S, P>) {
    assert!(cap.sale_id == object::id(sale), EWrongAdminCap);
}

fun assert_sender_is_buyer<S>(receipt: &Receipt<S>, ctx: &TxContext) {
    assert!(sale::receipt_buyer(receipt) == ctx.sender(), EBuyerOnly);
}

// === Setup (Phase: Init) ===

/// Creates a sale in `Init` phase as an *owned* value. The caller threads
/// it through setup calls in the same PTB, then transfers ownership via
/// `share_and_activate`. Returns the sale and its admin cap.
///
/// Caps:
///   - `hard_cap > 0` is required so the maximum raise is always bounded.
///   - `soft_cap` may be 0 (no minimum) or in `[1, hard_cap]`.
public fun create_sale<S, P>(
    rate: u64,
    hard_cap: u64,
    soft_cap: u64,
    opens_at_ms: u64,
    closes_at_ms: u64,
    ctx: &mut TxContext,
): (PrefundedSale<S, P>, SaleAdminCap<S, P>) {
    assert!(rate > 0, ERateZero);
    assert!(hard_cap > 0, EHardCapZero);
    assert!(soft_cap <= hard_cap, EInvalidCapsOrdering);
    assert!(opens_at_ms < closes_at_ms, EInvalidTimeRange);

    let sale = PrefundedSale<S, P> {
        id: object::new(ctx),
        inventory: balance::zero<S>(),
        total_allocated: 0,
        proceeds: balance::zero<P>(),
        rate,
        hard_cap,
        soft_cap,
        raised: 0,
        opens_at_ms,
        closes_at_ms,
        phase: sale::phase_init(),
        requires_allowlist: false,
        refund_vault_id: option::none(),
        refund_vault_cap: option::none(),
        per_buyer_cap: option::none(),
        contributions: option::none(),
    };
    let sale_id = object::id(&sale);
    let cap = SaleAdminCap<S, P> { id: object::new(ctx), sale_id };

    event::emit(SaleCreated<S, P> {
        sale_id,
        rate,
        hard_cap,
        soft_cap,
        opens_at_ms,
        closes_at_ms,
    });

    (sale, cap)
}

/// Deposits sale tokens into inventory. Multiple deposits allowed during
/// Init. Authority is implicit: during Init the sale is owned, so only
/// the admin who holds it can call this.
public fun deposit_inventory<S, P>(sale: &mut PrefundedSale<S, P>, inventory: Coin<S>) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    let amount = coin::value(&inventory);
    balance::join(&mut sale.inventory, coin::into_balance(inventory));
    event::emit(InventoryDeposited<S, P> {
        sale_id: object::id(sale),
        amount,
        inventory_after: balance::value(&sale.inventory),
    });
}

/// Configures per-buyer cap. Cannot be reset once configured. Must be
/// strictly positive — a zero cap would silently block every purchase.
public fun set_per_buyer_cap<S, P>(
    sale: &mut PrefundedSale<S, P>,
    per_buyer_cap: u64,
    ctx: &mut TxContext,
) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(option::is_none(&sale.per_buyer_cap), EPerBuyerCapAlreadySet);
    assert!(per_buyer_cap > 0, EPerBuyerCapZero);
    option::fill(&mut sale.per_buyer_cap, per_buyer_cap);
    option::fill(&mut sale.contributions, table::new<address, u64>(ctx));
    event::emit(PerBuyerCapSet<S, P> {
        sale_id: object::id(sale),
        cap: per_buyer_cap,
    });
}

/// Pairs a refund vault. Takes the vault by reference and the cap by
/// value (cap is consumed). Asserts:
///   - the cap belongs to the vault (`vault_id` match),
///   - the vault is in `Active` state,
///   - **the vault is empty** (`value == 0`). Pre-existing funds would
///     be stranded: the cap is wrapped after pairing, the sale's
///     `withdraw_proceeds` only touches `sale.proceeds`, and
///     `refund_vault::withdraw_all` requires `Closed` state which only
///     `finalize` reaches — and `finalize` does not return the cap.
///   - no prior vault has been paired.
public fun pair_refund_vault<S, P>(
    sale: &mut PrefundedSale<S, P>,
    vault: &RefundVault<P>,
    vault_cap: RefundVaultCap<P>,
) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(option::is_none(&sale.refund_vault_cap), EVaultAlreadyPaired);
    assert!(refund_vault::cap_vault_id(&vault_cap) == object::id(vault), EWrongVault);
    assert!(refund_vault::is_active(vault), EVaultNotActive);
    assert!(refund_vault::value(vault) == 0, EVaultNotEmpty);

    let vault_id = object::id(vault);
    option::fill(&mut sale.refund_vault_id, vault_id);
    option::fill(&mut sale.refund_vault_cap, vault_cap);
    event::emit(RefundVaultPaired<S, P> {
        sale_id: object::id(sale),
        vault_id,
    });
}

/// Enables allowlist mode. Idempotent guard — once enabled, cannot be
/// re-enabled (would issue duplicate `AllowlistAdmin<S>` objects which
/// could mint entries independently).
public fun enable_allowlist<S, P>(
    sale: &mut PrefundedSale<S, P>,
    ctx: &mut TxContext,
): AllowlistAdmin<S> {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(!sale.requires_allowlist, EAllowlistAlreadyEnabled);
    sale.requires_allowlist = true;
    let sale_id = object::id(sale);
    let admin = allowlist::new_admin<S>(sale_id, ctx);
    event::emit(AllowlistEnabled<S, P> {
        sale_id,
        allowlist_admin_id: object::id(&admin),
    });
    admin
}

/// Init → Active. Shares the sale. Asserts:
///   - a refund vault has been paired,
///   - inventory at activation covers `hard_cap * rate` (so the sale
///     can fulfil every purchase up to the hard cap without running out),
///   - `now < closes_at_ms` — activating after the window has already
///     elapsed would share a stale sale that immediately becomes
///     finalizable/cancellable with no purchase opportunity. Activation
///     before `opens_at_ms` is allowed (the time-window guard on
///     `purchase` keeps buyers out until the window opens).
public fun share_and_activate<S, P>(mut sale: PrefundedSale<S, P>, clock: &Clock) {
    assert!(sale::is_init(&sale.phase), ENotInit);
    assert!(option::is_some(&sale.refund_vault_cap), EVaultRequiredForActivate);

    // Inventory sufficiency: hard_cap * rate must fit in u64 and be
    // backed by current inventory.
    let required_128 = (sale.hard_cap as u128) * (sale.rate as u128);
    assert!(required_128 <= U64_MAX, EInventoryOverflowAtActivate);
    let required = required_128 as u64;
    assert!(balance::value(&sale.inventory) >= required, EInsufficientInventoryAtActivate);

    // Time sanity: activating after the window has expired means there
    // is no purchase opportunity.
    let activated_at_ms = clock::timestamp_ms(clock);
    assert!(activated_at_ms < sale.closes_at_ms, EActivationAfterClose);

    sale.phase = sale::phase_active();
    let sale_id = object::id(&sale);
    transfer::share_object(sale);
    event::emit(SaleActivated<S, P> { sale_id, activated_at_ms });
}

// === Active phase ===

/// Buyer purchases sale tokens. AllowEntry is required iff `requires_allowlist`.
/// Internally delivers the freshly-minted `Receipt<S>` to the buyer's
/// address (`ctx.sender()`). Payment is added to `sale.proceeds`.
///
/// All arithmetic that combines untrusted user input uses u128 widening
/// so a malicious / oversized payment aborts with a typed error rather
/// than the default arithmetic overflow.
public fun purchase<S, P>(
    sale: &mut PrefundedSale<S, P>,
    payment: Coin<P>,
    allow: Option<AllowEntry<S>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // 1. Phase + time guards
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    assert!(now >= sale.opens_at_ms && now <= sale.closes_at_ms, ESaleWindowClosed);

    // 2. Allowlist gate
    let buyer = ctx.sender();
    let entry_max = if (sale.requires_allowlist) {
        assert!(option::is_some(&allow), EAllowlistRequired);
        let entry = option::destroy_some(allow);
        allowlist::consume<S>(entry, object::id(sale), buyer)
    } else {
        assert!(option::is_none(&allow), EAllowlistNotRequired);
        option::destroy_none(allow);
        0
    };

    // 3. Payment & hard-cap checks (u128 widening prevents overflow)
    let paid = coin::value(&payment);
    assert!(paid > 0, EZeroPayment);
    let new_raised_128 = (sale.raised as u128) + (paid as u128);
    assert!(new_raised_128 <= U64_MAX, ERaisedOverflow);
    assert!(new_raised_128 <= (sale.hard_cap as u128), EHardCapExceeded);

    if (entry_max > 0) {
        assert!(paid <= entry_max, EPerEntryCapExceeded);
    };

    // 4. Per-buyer cap
    if (option::is_some(&sale.per_buyer_cap)) {
        let per_cap = *option::borrow(&sale.per_buyer_cap);
        let contribs = option::borrow_mut(&mut sale.contributions);
        let current = if (table::contains(contribs, buyer)) {
            *table::borrow(contribs, buyer)
        } else { 0 };
        let new_total_128 = (current as u128) + (paid as u128);
        assert!(new_total_128 <= U64_MAX, EContributionOverflow);
        assert!(new_total_128 <= (per_cap as u128), EPerBuyerCapExceeded);
        let new_total = new_total_128 as u64;
        if (table::contains(contribs, buyer)) {
            let slot = table::borrow_mut(contribs, buyer);
            *slot = new_total;
        } else {
            table::add(contribs, buyer, new_total);
        };
    };

    // 5. Compute allocation, check overflow, check inventory backing.
    let allocation_128 = (paid as u128) * (sale.rate as u128);
    assert!(allocation_128 <= U64_MAX, EAllocationOverflow);
    let allocation = allocation_128 as u64;
    // Activation-time invariant guarantees inventory >= hard_cap * rate,
    // so this check is theoretically redundant — but kept as a runtime
    // belt-and-braces against any future code path that might deposit
    // less inventory or change the invariant.
    let unallocated = balance::value(&sale.inventory) - sale.total_allocated;
    assert!(allocation <= unallocated, EInsufficientInventoryAtActivate);

    // 6. Apply state changes.
    sale.total_allocated = sale.total_allocated + allocation;
    sale.raised = new_raised_128 as u64;
    balance::join(&mut sale.proceeds, coin::into_balance(payment));

    // 7. Mint receipt and deliver to buyer.
    let sale_id = object::id(sale);
    let receipt = sale::new_receipt<S>(sale_id, buyer, paid, allocation, now, ctx);
    let receipt_id = object::id(&receipt);
    sale::deliver_receipt(receipt, buyer);

    event::emit(Purchased<S, P> {
        sale_id,
        buyer,
        receipt_id,
        paid,
        allocation,
        raised_after: sale.raised,
        purchased_at_ms: now,
    });
}

// === Closing (Active → Finalized | Cancelled) ===

/// **Permissionless.** Closes the sale as a success.
/// Allowed when phase is Active and either:
///   - `now > closes_at_ms` (window expired) and `raised >= soft_cap`, OR
///   - `raised >= hard_cap` (sold out — close early).
///
/// Takes the paired vault and flips it to `Closed`. No admin cap required;
/// the outcome is objective. The vault parameter is asserted to match
/// the one paired with this sale.
public fun finalize<S, P>(
    sale: &mut PrefundedSale<S, P>,
    vault: &mut RefundVault<P>,
    clock: &Clock,
) {
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    let window_closed = now > sale.closes_at_ms;
    let hard_cap_reached = sale.raised >= sale.hard_cap;
    assert!(window_closed || hard_cap_reached, ESaleWindowStillOpen);
    assert!(sale.raised >= sale.soft_cap, ESoftCapNotMet);

    let paired_id = *option::borrow(&sale.refund_vault_id);
    assert!(object::id(vault) == paired_id, EWrongVault);

    // Flip the paired vault to Closed. Indexers and ops tooling see a
    // matched terminal state on both objects.
    {
        let cap_ref = option::borrow(&sale.refund_vault_cap);
        refund_vault::flip_to_closed(vault, cap_ref);
    };

    sale.phase = sale::phase_finalized();
    event::emit(SaleFinalized<S, P> {
        sale_id: object::id(sale),
        raised: sale.raised,
        closed_at_ms: now,
    });
}

/// **Permissionless.** Closes the sale as a soft-cap miss after the
/// window has expired.
/// Allowed when:
///   - phase is Active,
///   - `now > closes_at_ms`,
///   - `soft_cap > 0` (otherwise the sale has no failure outcome),
///   - `raised < soft_cap`.
///
/// Drains proceeds into the paired vault and flips vault to Refunding.
public fun cancel_after_close<S, P>(
    sale: &mut PrefundedSale<S, P>,
    vault: &mut RefundVault<P>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    assert!(now > sale.closes_at_ms, ESaleWindowStillOpen);
    assert!(sale.soft_cap > 0 && sale.raised < sale.soft_cap, ESoftCapMet);

    do_cancel(sale, vault, CancelReason::SoftCapMissed, now);
    let _ = ctx;
}

/// **Admin-only.** Emergency cancellation **while phase is Active and
/// the window has not yet closed**. This includes the pre-open window
/// (`now < opens_at_ms`) — admin can preemptively cancel a sale that
/// hasn't started yet (no buyers, vault stays empty), which is useful
/// if a bug or compliance issue is discovered before purchases begin.
///
/// Guards (designed to prevent rugging a successful sale):
///   - phase Active,
///   - `now <= closes_at_ms` (after close, use the permissionless paths),
///   - `raised < hard_cap` (cannot cancel a sold-out sale),
///   - `soft_cap == 0` OR `raised < soft_cap` (cannot cancel a sale that
///     would have succeeded — admin must let it finalize instead).
///
/// Drains proceeds into the paired vault and flips vault to Refunding.
public fun cancel_emergency<S, P>(
    sale: &mut PrefundedSale<S, P>,
    cap: &SaleAdminCap<S, P>,
    vault: &mut RefundVault<P>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_admin(sale, cap);
    assert!(sale::is_active(&sale.phase), ENotActive);
    let now = clock::timestamp_ms(clock);
    // Critical: emergency cancel is a *during-window* admin override.
    // After close, the permissionless `finalize` / `cancel_after_close`
    // paths take over and the admin loses the unilateral cancel power.
    assert!(now <= sale.closes_at_ms, EEmergencyCancelAfterClose);
    assert!(sale.raised < sale.hard_cap, ESaleAlreadyComplete);
    assert!(sale.soft_cap == 0 || sale.raised < sale.soft_cap, ESoftCapMet);

    do_cancel(sale, vault, CancelReason::AdminEmergency, now);
    let _ = ctx;
}

/// Internal: the shared body of both cancellation paths.
fun do_cancel<S, P>(
    sale: &mut PrefundedSale<S, P>,
    vault: &mut RefundVault<P>,
    reason: CancelReason,
    now: u64,
) {
    let paired_id = *option::borrow(&sale.refund_vault_id);
    assert!(object::id(vault) == paired_id, EWrongVault);

    // Drain proceeds → vault and flip vault state, using the wrapped cap.
    let amount = balance::value(&sale.proceeds);
    let proceeds_balance = balance::split(&mut sale.proceeds, amount);
    {
        let cap_ref = option::borrow(&sale.refund_vault_cap);
        refund_vault::deposit(vault, cap_ref, proceeds_balance);
        refund_vault::flip_to_refunding(vault, cap_ref);
    };

    sale.phase = sale::phase_cancelled();

    event::emit(SaleCancelled<S, P> {
        sale_id: object::id(sale),
        raised: sale.raised,
        reason,
        closed_at_ms: now,
    });
}

// === Success path (Finalized) ===

/// Buyer claims allocation. Destroys receipt, returns Coin<S>.
/// Requires `ctx.sender() == receipt.buyer` — receipts are non-transferable
/// (see `sale.move` module doc) so only the original buyer can call this.
public fun claim<S, P>(
    sale: &mut PrefundedSale<S, P>,
    receipt: Receipt<S>,
    ctx: &mut TxContext,
): Coin<S> {
    assert!(sale::is_finalized(&sale.phase), ENotFinalized);
    assert!(sale::receipt_sale_id(&receipt) == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, _paid, allocation, _ts) = sale::consume_receipt(receipt);

    sale.total_allocated = sale.total_allocated - allocation;
    let payout = balance::split(&mut sale.inventory, allocation);

    event::emit(Claimed<S, P> {
        sale_id: object::id(sale),
        buyer,
        receipt_id,
        amount: allocation,
    });

    coin::from_balance(payout, ctx)
}

/// Convenience: claim multiple receipts in one call. Returns a single
/// merged `Coin<S>`. Aborts on the first invalid receipt — partial
/// success is not supported (it would complicate the caller's recovery).
public fun claim_all<S, P>(
    sale: &mut PrefundedSale<S, P>,
    mut receipts: vector<Receipt<S>>,
    ctx: &mut TxContext,
): Coin<S> {
    let mut total = coin::zero<S>(ctx);
    while (!vector::is_empty(&receipts)) {
        let r = vector::pop_back(&mut receipts);
        coin::join(&mut total, claim(sale, r, ctx));
    };
    vector::destroy_empty(receipts);
    total
}

/// Admin withdraws raised proceeds. Phase must be Finalized.
public fun withdraw_proceeds<S, P>(
    sale: &mut PrefundedSale<S, P>,
    cap: &SaleAdminCap<S, P>,
    ctx: &mut TxContext,
): Coin<P> {
    assert_admin(sale, cap);
    assert!(sale::is_finalized(&sale.phase), ENotFinalized);
    let amount = balance::value(&sale.proceeds);
    let part = balance::split(&mut sale.proceeds, amount);
    event::emit(ProceedsWithdrawn<S, P> {
        sale_id: object::id(sale),
        amount,
    });
    coin::from_balance(part, ctx)
}

/// Admin withdraws unsold inventory — strictly the unallocated portion
/// (`inventory.value() - total_allocated`). Outstanding receipts are not
/// invalidated; their backing remains in `inventory` even after this call.
///
/// Valid in Finalized or Cancelled.
public fun withdraw_unsold_inventory<S, P>(
    sale: &mut PrefundedSale<S, P>,
    cap: &SaleAdminCap<S, P>,
    ctx: &mut TxContext,
): Coin<S> {
    assert_admin(sale, cap);
    assert!(sale::is_finalized(&sale.phase) || sale::is_cancelled(&sale.phase), ENotTerminal);
    let unallocated = balance::value(&sale.inventory) - sale.total_allocated;
    let part = balance::split(&mut sale.inventory, unallocated);
    event::emit(InventoryWithdrawn<S, P> {
        sale_id: object::id(sale),
        amount: unallocated,
    });
    coin::from_balance(part, ctx)
}

// === Failure path (Cancelled) ===

/// Buyer refunds via the paired vault. Sale's wrapped vault cap is used
/// internally. Destroys receipt, returns Coin<P>. Requires
/// `ctx.sender() == receipt.buyer`.
public fun refund<S, P>(
    sale: &mut PrefundedSale<S, P>,
    vault: &mut RefundVault<P>,
    receipt: Receipt<S>,
    ctx: &mut TxContext,
): Coin<P> {
    assert!(sale::is_cancelled(&sale.phase), ENotCancelled);
    assert!(sale::receipt_sale_id(&receipt) == object::id(sale), EReceiptSaleMismatch);
    assert_sender_is_buyer(&receipt, ctx);
    let paired_vault_id = *option::borrow(&sale.refund_vault_id);
    assert!(object::id(vault) == paired_vault_id, EWrongVault);

    let receipt_id = object::id(&receipt);
    let (_sale_id, buyer, paid, allocation, _ts) = sale::consume_receipt(receipt);

    sale.total_allocated = sale.total_allocated - allocation;

    let payment = {
        let cap_ref = option::borrow(&sale.refund_vault_cap);
        refund_vault::release_balance(vault, cap_ref, paid)
    };

    event::emit(Refunded<S, P> {
        sale_id: object::id(sale),
        buyer,
        receipt_id,
        amount: paid,
    });

    coin::from_balance(payment, ctx)
}

// === Views ===

public fun phase<S, P>(sale: &PrefundedSale<S, P>): Phase { sale.phase }

public fun raised<S, P>(sale: &PrefundedSale<S, P>): u64 { sale.raised }

public fun rate<S, P>(sale: &PrefundedSale<S, P>): u64 { sale.rate }

public fun hard_cap<S, P>(sale: &PrefundedSale<S, P>): u64 { sale.hard_cap }

public fun soft_cap<S, P>(sale: &PrefundedSale<S, P>): u64 { sale.soft_cap }

public fun opens_at_ms<S, P>(sale: &PrefundedSale<S, P>): u64 { sale.opens_at_ms }

public fun closes_at_ms<S, P>(sale: &PrefundedSale<S, P>): u64 { sale.closes_at_ms }

public fun requires_allowlist<S, P>(sale: &PrefundedSale<S, P>): bool { sale.requires_allowlist }

public fun inventory_total<S, P>(sale: &PrefundedSale<S, P>): u64 {
    balance::value(&sale.inventory)
}

public fun total_allocated<S, P>(sale: &PrefundedSale<S, P>): u64 { sale.total_allocated }

public fun inventory_remaining<S, P>(sale: &PrefundedSale<S, P>): u64 {
    balance::value(&sale.inventory) - sale.total_allocated
}

public fun proceeds_amount<S, P>(sale: &PrefundedSale<S, P>): u64 { balance::value(&sale.proceeds) }

public fun is_open<S, P>(sale: &PrefundedSale<S, P>, clock: &Clock): bool {
    if (!sale::is_active(&sale.phase)) { return false };
    let now = clock::timestamp_ms(clock);
    now >= sale.opens_at_ms && now <= sale.closes_at_ms
}

public fun has_reached_soft_cap<S, P>(sale: &PrefundedSale<S, P>): bool {
    sale.raised >= sale.soft_cap
}

public fun has_reached_hard_cap<S, P>(sale: &PrefundedSale<S, P>): bool {
    sale.raised >= sale.hard_cap
}

public fun cap_sale_id<S, P>(c: &SaleAdminCap<S, P>): ID { c.sale_id }
