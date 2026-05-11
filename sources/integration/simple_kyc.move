/// Example compliance module — the kind of code an integrator owns.
///
/// `openzeppelin_sales::allowlist` ships a typed slot (`AllowlistAdmin<S>`,
/// `AllowEntry<S>`); it does **not** ship verification logic. Each consumer
/// wires their own. This module shows one realistic pattern: an admin-
/// managed verified-buyer table with **per-sale, per-entry caps set by
/// the compliance officer**, supporting multiple concurrent sales of the
/// same token.
///
/// ### Per-entry vs cumulative — read this carefully
///
/// The value stored in `verified` is the **`max_per_entry`** cap — the
/// maximum payment per `AllowEntry<MY_TOKEN>`. It is **not** a cumulative
/// per-buyer allocation cap. A verified buyer can call `mint_entry` any
/// number of times in any number of PTBs, each time getting a fresh
/// entry up to `max_per_entry`, and each entry feeds a separate
/// `purchase` call.
///
/// If you want a **cumulative per-buyer cap** across all of a buyer's
/// purchases, configure it at the **sale** level via
/// `prefunded_sale::set_per_buyer_cap`. That cap is enforced inside
/// `purchase` against the running `contributions[buyer]` total — the
/// KYC module cannot enforce it on its own because it does not see
/// purchase outcomes.
///
/// The two caps compose like this on every purchase:
///   - the entry's `max_per_entry` bounds *this single* payment;
///   - the sale's `per_buyer_cap` bounds the *sum* of all the buyer's
///     payments to this sale.
///
/// `sale_factory::deploy_strategic_round` sets both. If you copy this
/// module standalone, remember the sale-level cap is your responsibility.
///
/// Key shapes:
///   - `verified: Table<KycKey, u64>` — composite key `(buyer, sale_id)`
///     maps to `max_per_entry`. A single buyer can be verified for
///     several sales independently, each with its own per-entry cap.
///   - `admins: Table<ID, AllowlistAdmin<MY_TOKEN>>` — one entry per
///     registered sale.
///
/// ### Bootstrap order
///
/// 1. Publish the package and the sales library together.
/// 2. `simple_kyc::deploy` — creates the shared `KycModule` and yields
///    `KycAdminCap` to the compliance officer.
/// 3. For each sale to KYC-gate:
///    - `prefunded_sale::create_sale` then `enable_allowlist` →
///      `AllowlistAdmin<MY_TOKEN>`.
///    - `simple_kyc::register_admin(kyc, kyc_cap, allow_admin)`.
/// 4. The compliance officer verifies buyers per sale via
///    `verify_buyer(kyc, cap, buyer, sale_id, max_per_entry)`.
/// 5. Verified buyers call `mint_entry(kyc, sale_id)` and `purchase`
///    in the **same PTB**.
///
/// ### Recovery
///
/// `KycModule` is a **shared** object — it cannot be transferred. The
/// unit of recovery is `KycAdminCap`: owned and transferable, so a
/// compromised compliance officer can be replaced by transferring the
/// cap to a new operator (via multisig PTB, etc.). The shared module
/// keeps all state intact.
///
/// **Footgun:** if `KycAdminCap` is lost outright, no new buyers can
/// be verified and no new sales can be registered. Existing entries
/// continue to work. Wrap the cap in an access-controlled holder.
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

/// Composite key for the verified table. A buyer is verified
/// *per-sale*, with a per-sale per-entry cap.
public struct KycKey has copy, drop, store {
    buyer: address,
    sale_id: ID,
}

/// Compliance module. Shared.
public struct KycModule has key {
    id: UID,
    /// (buyer, sale_id) → max_per_entry (0 = no per-entry cap; the
    /// sale's own per-buyer cap, if any, still applies).
    verified: Table<KycKey, u64>,
    /// sale_id → admin. One per registered sale.
    admins: Table<ID, AllowlistAdmin<MY_TOKEN>>,
}

/// Authority over this KYC module. Owned, transferable.
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

/// Register an `AllowlistAdmin<MY_TOKEN>` for a specific sale.
public fun register_admin(kyc: &mut KycModule, cap: &KycAdminCap, admin: AllowlistAdmin<MY_TOKEN>) {
    assert_cap(kyc, cap);
    let sale_id = allowlist::admin_sale_id(&admin);
    assert!(!table::contains(&kyc.admins, sale_id), ESaleAlreadyRegistered);
    table::add(&mut kyc.admins, sale_id, admin);
    event::emit(SaleRegistered { kyc_id: object::id(kyc), sale_id });
}

/// Verify a buyer for a specific sale at a specific **per-entry** cap.
///
/// `max_per_entry` is the upper bound on the payment of one
/// `AllowEntry<MY_TOKEN>` minted for this buyer-and-sale. It is **not**
/// a cumulative per-buyer cap — a verified buyer can mint multiple
/// entries (one per `mint_entry` call) and purchase repeatedly. For
/// a cumulative cap, configure `prefunded_sale::set_per_buyer_cap`
/// at the sale level. See the module-level docs for the composition.
///
/// `max_per_entry = 0` means "no per-entry cap" (the sale's own
/// per-buyer cap, if configured, still applies).
///
/// **Requires the sale to be registered first** (via `register_admin`).
/// This prevents operators from creating dead verification records for
/// sale IDs that don't exist — `mint_entry` would later reject them
/// anyway, but failing fast at verification surfaces the mistake
/// immediately. Recommended bootstrap order: `register_admin` then
/// `verify_buyer`.
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

/// Update an already-verified buyer's per-entry cap *for one sale*.
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
public fun revoke_buyer(kyc: &mut KycModule, cap: &KycAdminCap, buyer: address, sale_id: ID) {
    assert_cap(kyc, cap);
    let key = KycKey { buyer, sale_id };
    assert!(table::contains(&kyc.verified, key), ENotVerified);
    table::remove(&mut kyc.verified, key);
    event::emit(BuyerRevoked { kyc_id: object::id(kyc), buyer, sale_id });
}

// === Buyer-facing: mint an entry ===

/// Verified buyers call this to mint a fresh `AllowEntry<MY_TOKEN>` they
/// can immediately consume in a `prefunded_sale::purchase` call in the
/// **same PTB**.
///
/// Looks up the per-entry cap via `(sender, sale_id)` — buyers cannot
/// choose their own cap.
public fun mint_entry(kyc: &KycModule, sale_id: ID, ctx: &TxContext): AllowEntry<MY_TOKEN> {
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
