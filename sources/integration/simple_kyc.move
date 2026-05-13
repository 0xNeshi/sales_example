/// Example compliance module — integrator-owned.
///
/// `sales_example::allowlist` ships a typed slot
/// (`AllowlistAdmin<S>`, `AllowEntry<S>`) but no verification logic.
/// This module is one realistic shape an integrator can use to wire
/// the slot to their compliance scheme. The library does not depend
/// on this module; replacing it with a merkle-proof verifier, an
/// on-chain tier staker, an off-chain accredited-investor oracle,
/// etc. requires no library change.
///
/// Tables this module owns:
///
/// - `verified: Table<KycKey, u64>` — composite key `(buyer, sale_id)`
///   maps to the buyer's per-entry payment cap for that sale. The
///   compliance officer sets the cap; the buyer cannot.
/// - `admins: Table<ID, AllowlistAdmin<MY_TOKEN>>` — one
///   `AllowlistAdmin<MY_TOKEN>` per registered sale. A single KYC
///   module can serve multiple concurrent sales of the same token
///   (private → strategic → public) and reuse one verified list.
///
/// ### `max_per_entry` vs cumulative
///
/// The `u64` stored in `verified` is **per-entry**, not cumulative:
/// it bounds the payment of a single `AllowEntry<MY_TOKEN>`. A
/// verified buyer can call `mint_entry` repeatedly and submit
/// multiple `purchase` calls, each up to `max_per_entry`.
///
/// **The cumulative bound lives on the sale**, not here. Configure
/// `prefunded_sale::set_per_buyer_cap` if a single buyer must not
/// purchase more than some total across all their purchases. The two
/// caps compose:
/// - per-entry bounds *this single* payment;
/// - per-buyer bounds the *sum* of the buyer's payments to the sale.
///
/// `sale_factory::deploy_strategic_round` sets both. If this module
/// is copied without `set_per_buyer_cap` configured on the sale, one
/// verified buyer can buy the entire allocation up to `hard_cap`.
///
/// ### Bootstrap order
///
/// 1. `simple_kyc::deploy` — share the `KycModule`, owner receives
///    `KycAdminCap`.
/// 2. For each sale to gate:
///    - Create the sale and call `enable_allowlist`.
///    - `register_admin` routes the returned `AllowlistAdmin<MY_TOKEN>`
///      into this module, keyed by `sale_id`.
/// 3. The compliance officer verifies buyers per sale via
///    `verify_buyer(kyc, cap, buyer, sale_id, max_per_entry)`.
///    `verify_buyer` requires the sale to be registered first, so
///    typos in `sale_id` fail fast rather than producing dead
///    records.
/// 4. Verified buyers call `mint_entry(kyc, sale_id)` and
///    `purchase` in the same PTB.
///
/// ### Recovery
///
/// `KycModule` is shared and cannot be transferred. The unit of
/// recovery is `KycAdminCap`: owned and transferable. A compromised
/// compliance officer can be replaced by transferring the cap to a
/// new operator address (via a multisig PTB, for instance). The
/// shared module retains all state.
///
/// If `KycAdminCap` itself is lost, no new buyers can be verified
/// and no new sales can be registered. Existing entries continue to
/// work. Hold the cap in an access-controlled wrapper.
module sales_example::simple_kyc;

use sales_example::allowlist::{Self, AllowEntry, AllowlistAdmin};
use sales_example::my_token::MY_TOKEN;

use sui::event;
use sui::table::{Self, Table};

// === Errors ===

#[error(code = 0)]
const ENotVerified: vector<u8> = "Buyer is not verified for this sale";
#[error(code = 1)]
const EAlreadyVerified: vector<u8> = "Buyer is already verified for this sale";
#[error(code = 2)]
const EWrongKycCap: vector<u8> = "Cap does not match this KYC module";
#[error(code = 3)]
const ESaleAlreadyRegistered: vector<u8> = "An admin for this sale_id is already registered";
#[error(code = 4)]
const ESaleNotRegistered: vector<u8> = "No allowlist admin registered for this sale_id";

// === Types ===

/// Composite key for the verified table: a buyer is verified
/// per-sale, with a per-sale per-entry cap.
public struct KycKey has copy, drop, store {
    buyer: address,
    sale_id: ID,
}

/// Compliance module. Shared.
public struct KycModule has key {
    id: UID,
    /// `(buyer, sale_id) → max_per_entry`. `0` means "no per-entry
    /// cap" (the sale's own per-buyer cap, if configured, still
    /// applies).
    verified: Table<KycKey, u64>,
    /// `sale_id → admin`. One per registered sale.
    admins: Table<ID, AllowlistAdmin<MY_TOKEN>>,
}

/// Authority over this KYC module. Owned, transferable. Compromised-
/// officer recovery is "transfer the cap to a new address."
public struct KycAdminCap has key, store {
    id: UID,
    kyc_id: ID,
}

// === Events ===

public struct KycModuleCreated has copy, drop {
    kyc_id: ID,
    cap_id: ID,
}

public struct SaleRegistered has copy, drop {
    kyc_id: ID,
    sale_id: ID,
}

public struct BuyerVerified has copy, drop {
    kyc_id: ID,
    buyer: address,
    sale_id: ID,
    max_per_entry: u64,
}

public struct BuyerCapUpdated has copy, drop {
    kyc_id: ID,
    buyer: address,
    sale_id: ID,
    new_max_per_entry: u64,
}

public struct BuyerRevoked has copy, drop {
    kyc_id: ID,
    buyer: address,
    sale_id: ID,
}

// === Deploy ===

/// Create + share the `KycModule`. Transfers `KycAdminCap` to the
/// caller. Returns the IDs the caller's tooling needs to track both
/// objects across transactions.
#[allow(lint(self_transfer))]
public fun deploy(ctx: &mut TxContext): (ID, ID) {
    let kyc = KycModule {
        id: object::new(ctx),
        verified: table::new<KycKey, u64>(ctx),
        admins: table::new<ID, AllowlistAdmin<MY_TOKEN>>(ctx),
    };
    let kyc_id = object::id(&kyc);
    let cap = KycAdminCap { id: object::new(ctx), kyc_id };
    let cap_id = object::id(&cap);

    event::emit(KycModuleCreated { kyc_id, cap_id });

    transfer::share_object(kyc);
    transfer::transfer(cap, ctx.sender());
    (kyc_id, cap_id)
}

// === Admin operations ===

/// Register an `AllowlistAdmin<MY_TOKEN>` issued by a sale's
/// `enable_allowlist`. The `sale_id` is read directly from the admin
/// so the caller cannot misroute it. Aborts if a different admin is
/// already registered for the same sale.
public fun register_admin(
    kyc: &mut KycModule,
    cap: &KycAdminCap,
    admin: AllowlistAdmin<MY_TOKEN>,
) {
    assert_cap(kyc, cap);
    let sale_id = allowlist::admin_sale_id(&admin);
    assert!(!table::contains(&kyc.admins, sale_id), ESaleAlreadyRegistered);
    table::add(&mut kyc.admins, sale_id, admin);
    event::emit(SaleRegistered { kyc_id: object::id(kyc), sale_id });
}

/// Verify a buyer for a specific sale, at a specific per-entry cap.
///
/// **Per-entry, not cumulative.** See module docs.
///
/// `max_per_entry = 0` disables the per-entry cap (the sale's own
/// `per_buyer_cap`, if configured, still applies).
///
/// Aborts if the sale is not yet registered. Recommended order:
/// `register_admin` first, then `verify_buyer`.
public fun verify_buyer(
    kyc: &mut KycModule,
    cap: &KycAdminCap,
    buyer: address,
    sale_id: ID,
    max_per_entry: u64,
) {
    assert_cap(kyc, cap);
    assert!(table::contains(&kyc.admins, sale_id), ESaleNotRegistered);
    let key = KycKey { buyer, sale_id };
    assert!(!table::contains(&kyc.verified, key), EAlreadyVerified);
    table::add(&mut kyc.verified, key, max_per_entry);
    event::emit(BuyerVerified {
        kyc_id: object::id(kyc),
        buyer,
        sale_id,
        max_per_entry,
    });
}

/// Update an already-verified buyer's per-entry cap for one sale.
/// Other sales the buyer is verified for are unaffected.
public fun set_buyer_cap(
    kyc: &mut KycModule,
    cap: &KycAdminCap,
    buyer: address,
    sale_id: ID,
    new_max_per_entry: u64,
) {
    assert_cap(kyc, cap);
    let key = KycKey { buyer, sale_id };
    assert!(table::contains(&kyc.verified, key), ENotVerified);
    let slot = table::borrow_mut(&mut kyc.verified, key);
    *slot = new_max_per_entry;
    event::emit(BuyerCapUpdated {
        kyc_id: object::id(kyc),
        buyer,
        sale_id,
        new_max_per_entry,
    });
}

/// Remove a buyer's verification for a specific sale.
public fun revoke_buyer(
    kyc: &mut KycModule,
    cap: &KycAdminCap,
    buyer: address,
    sale_id: ID,
) {
    assert_cap(kyc, cap);
    let key = KycKey { buyer, sale_id };
    assert!(table::contains(&kyc.verified, key), ENotVerified);
    table::remove(&mut kyc.verified, key);
    event::emit(BuyerRevoked { kyc_id: object::id(kyc), buyer, sale_id });
}

// === Buyer-facing: mint an entry ===

/// Mint an `AllowEntry<MY_TOKEN>` for `ctx.sender()` against the
/// registered sale at `sale_id`. The entry's `max_amount` is read
/// from the `verified` table — buyers cannot choose their own cap.
///
/// Aborts if the sender is not verified for this sale, or if the
/// sale is not registered.
///
/// The entry has no abilities; it must be consumed by
/// `prefunded_sale::purchase` in the same PTB.
public fun mint_entry(
    kyc: &KycModule,
    sale_id: ID,
    ctx: &TxContext,
): AllowEntry<MY_TOKEN> {
    let buyer = ctx.sender();
    let key = KycKey { buyer, sale_id };
    assert!(table::contains(&kyc.verified, key), ENotVerified);
    assert!(table::contains(&kyc.admins, sale_id), ESaleNotRegistered);

    let max = *table::borrow(&kyc.verified, key);
    let admin = table::borrow(&kyc.admins, sale_id);
    allowlist::new_entry<MY_TOKEN>(admin, buyer, max)
}

// === Views ===

public fun is_verified(kyc: &KycModule, buyer: address, sale_id: ID): bool {
    table::contains(&kyc.verified, KycKey { buyer, sale_id })
}

public fun max_per_entry(kyc: &KycModule, buyer: address, sale_id: ID): u64 {
    *table::borrow(&kyc.verified, KycKey { buyer, sale_id })
}

public fun has_sale_registered(kyc: &KycModule, sale_id: ID): bool {
    table::contains(&kyc.admins, sale_id)
}

public fun cap_kyc_id(c: &KycAdminCap): ID { c.kyc_id }

// === Internal ===

fun assert_cap(kyc: &KycModule, cap: &KycAdminCap) {
    assert!(cap.kyc_id == object::id(kyc), EWrongKycCap);
}
