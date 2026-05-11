/// Shared types used across the `openzeppelin_sales` family of sale flavors.
///
/// This module owns:
///   - `Phase` — the lifecycle enum every sale flavor shares.
///   - `Receipt<S>` — the per-buyer claim ticket.
///
/// ### Why `Receipt<S>` has `key` only (no `store`)
///
/// Receipts are **non-transferable by design**. With only the `key` ability:
///   - `transfer::public_transfer` rejects them (requires `key + store`).
///   - `transfer::transfer` is restricted to this module.
///   - They cannot be wrapped as a field inside another struct
///     (fields require `store`).
///
/// The only way a receipt moves between addresses is via the library's
/// own `deliver_receipt`, which runs at purchase time and sends the
/// receipt to the recorded buyer. After that, the receipt stays with
/// that buyer until they consume it via `claim` or `refund`.
///
/// This eliminates two footguns we discovered during review:
///   1. **KYC bypass at distribution.** A verified buyer transferring
///      their receipt to an unverified address that then claims.
///   2. **Stranded allocations.** A buyer transferring their receipt to
///      an address that can't claim (or won't), permanently pinning
///      inventory.
///
/// Partners who genuinely need a transferable secondary market for
/// allocations cannot wrap this `Receipt<S>` directly (no `store`).
/// They would need to either (a) consume the receipt via `claim`/`refund`
/// and trade the resulting `Coin<S>` / `Coin<P>` instead, or (b) build
/// their own ticket type with appropriate abilities and compliance hooks.
///
/// ### Tier-1 / Tier-2 boundary (teaching example caveat)
///
/// The `new_receipt`, `deliver_receipt`, and `consume_receipt` helpers
/// below are `public(package)`. In a real deployment where this library
/// lives in its own Move package, integrator code cannot reach them. In
/// **this** single-package example, the `sources/integration/` modules
/// technically *could* call them — but doing so would defeat the
/// audit-boundary story. They don't, and they shouldn't. The Tier-2
/// modules in this example only consume the public API surface.
module sales_example::sale;

// === Phase ===

/// Lifecycle phases shared by every sale flavor.
///
/// Transitions:
///   Init      → Active                     (admin calls `share_and_activate`)
///   Active    → Finalized | Cancelled      (terminal)
public enum Phase has copy, drop, store {
    /// Sale is created but not yet shared. Admin deposits inventory and
    /// wires hooks here. Holding the sale by `&mut` is the authority.
    Init,
    /// Sale is shared and accepting purchases (subject to `[opens_at, closes_at]`).
    Active,
    /// Successful close: claims enabled, proceeds withdrawable.
    Finalized,
    /// Failed close: refunds enabled via the paired vault.
    Cancelled,
}

// === Receipt ===

/// Per-buyer claim ticket. One receipt per purchase. Buyer-owned.
/// **`key` only** — non-transferable (see module doc).
public struct Receipt<phantom S> has key {
    id: UID,
    /// Sale this receipt was issued by. Verified at claim/refund.
    sale_id: ID,
    /// Buyer of record. Claim and refund require `ctx.sender() == buyer`.
    buyer: address,
    /// Payment amount (in P smallest units).
    paid: u64,
    /// Sale token allocation (in S smallest units).
    allocation: u64,
    /// Time of purchase (Sui Clock ms).
    purchased_at_ms: u64,
}

// === Public read-only accessors ===

public fun receipt_sale_id<S>(r: &Receipt<S>): ID { r.sale_id }

public fun receipt_buyer<S>(r: &Receipt<S>): address { r.buyer }

public fun receipt_paid<S>(r: &Receipt<S>): u64 { r.paid }

public fun receipt_allocation<S>(r: &Receipt<S>): u64 { r.allocation }

public fun receipt_purchased_at_ms<S>(r: &Receipt<S>): u64 { r.purchased_at_ms }

// === Phase predicates ===

public fun is_init(p: &Phase): bool {
    match (p) {
        Phase::Init => true,
        _ => false,
    }
}

public fun is_active(p: &Phase): bool {
    match (p) {
        Phase::Active => true,
        _ => false,
    }
}

public fun is_finalized(p: &Phase): bool {
    match (p) {
        Phase::Finalized => true,
        _ => false,
    }
}

public fun is_cancelled(p: &Phase): bool {
    match (p) {
        Phase::Cancelled => true,
        _ => false,
    }
}

// === Package-internal constructors and helpers ===
//
// These functions are **library-internal**. In a multi-package
// deployment of the audit-boundary library, `public(package)` would
// restrict them to other library modules. In this single-package
// teaching example they are technically reachable by the
// `sources/integration/` modules; integrator code should not call them.

/// Mint a fresh receipt. Only the sale flavors call this.
public(package) fun new_receipt<S>(
    sale_id: ID,
    buyer: address,
    paid: u64,
    allocation: u64,
    purchased_at_ms: u64,
    ctx: &mut TxContext,
): Receipt<S> {
    Receipt<S> {
        id: object::new(ctx),
        sale_id,
        buyer,
        paid,
        allocation,
        purchased_at_ms,
    }
}

/// Transfer a freshly-minted receipt to its buyer. Only callable from
/// the sales package — this is the **single** transfer path for receipts.
/// External code has no other way to move a receipt across addresses,
/// which is what makes receipts effectively non-transferable.
public(package) fun deliver_receipt<S>(receipt: Receipt<S>, to: address) {
    transfer::transfer(receipt, to);
}

/// Destructively read receipt fields, returning them.
/// Used by `prefunded_sale::claim`, `prefunded_sale::refund`,
/// and `claim_vested` adapters. The receipt's UID is deleted.
public(package) fun consume_receipt<S>(r: Receipt<S>): (ID, address, u64, u64, u64) {
    let Receipt { id, sale_id, buyer, paid, allocation, purchased_at_ms } = r;
    object::delete(id);
    (sale_id, buyer, paid, allocation, purchased_at_ms)
}

// === Phase factories (internal) ===

public(package) fun phase_init(): Phase { Phase::Init }

public(package) fun phase_active(): Phase { Phase::Active }

public(package) fun phase_finalized(): Phase { Phase::Finalized }

public(package) fun phase_cancelled(): Phase { Phase::Cancelled }
