/// Typed slot for compliance hooks. The library does **not** ship a KYC
/// implementation; we ship the typed slot and let consumers wire whatever
/// verification they want — KYC contract, tier checker, merkle verifier, etc.
///
/// Two types live here:
///   - `AllowEntry<S>` — hot-potato ticket. Created by the consumer's
///     compliance module and consumed by `prefunded_sale::purchase` in
///     the *same PTB*. No abilities means it cannot be stored, copied,
///     replayed, or transferred to a different recipient.
///   - `AllowlistAdmin<S>` — owned capability. Issued by
///     `prefunded_sale::enable_allowlist` and held by the consumer's
///     compliance module (typically wrapped inside its own object).
///
/// **Footgun:** if the consumer loses the `AllowlistAdmin<S>` (sends to a
/// non-existent address, transfers to `0x0`, etc.), the sale becomes
/// uncompletable because no entries can be minted. The library does not
/// provide an emergency override — that would be a centralization vector.
/// Hold the admin in an access-controlled wrapper you can recover from.
///
/// ### Tier-1 / Tier-2 boundary (teaching example caveat)
///
/// `new_admin` and `consume` are `public(package)`. In a real deployment
/// where this library lives in its own Move package, integrator code
/// cannot reach them — only sibling library modules (such as
/// `prefunded_sale`) can. In **this** single-package example, the
/// `sources/integration/` modules technically *could* call them, which
/// would let an integrator forge `AllowlistAdmin<S>` objects bypassing
/// `enable_allowlist`, or skip the `purchase` flow entirely. Integration
/// code here does not do that, but the type system cannot enforce the
/// boundary until the library is extracted. See the example README's
/// "Tier-1 / Tier-2 boundary" section for the full list of affected
/// helpers.
module sales_example::allowlist;

// === Errors ===

#[error(code = 0)]
const EWrongSaleId: vector<u8> = "AllowEntry sale_id does not match expected sale";
#[error(code = 1)]
const EWrongBuyer: vector<u8> = "AllowEntry buyer does not match transaction sender";

// === Types ===

/// Hot-potato compliance ticket. NO ABILITIES — must be consumed in the
/// same tx where it's minted.
///
/// Fields:
///   - `sale_id` binds the entry to one specific sale.
///   - `buyer` binds the entry to one specific recipient.
///   - `max_amount` is a per-entry payment cap (0 = no per-entry cap).
public struct AllowEntry<phantom S> {
    sale_id: ID,
    buyer: address,
    max_amount: u64,
}

/// Authority to mint `AllowEntry<S>` for a specific sale. Owned and
/// transferable so the consumer can wrap it inside a compliance module.
public struct AllowlistAdmin<phantom S> has key, store {
    id: UID,
    sale_id: ID,
}

// === Library-internal: admin minting ===

/// Mint a fresh admin for a given sale. Only `prefunded_sale::enable_allowlist`
/// calls this.
public(package) fun new_admin<S>(sale_id: ID, ctx: &mut TxContext): AllowlistAdmin<S> {
    AllowlistAdmin<S> { id: object::new(ctx), sale_id }
}

// === Public: compliance module mints entries ===

/// Mint a fresh allow entry. The consumer's compliance module calls this
/// after performing whatever verification it requires (KYC lookup, merkle
/// proof, tier check, etc.).
///
/// `buyer` must be the actual transaction sender at `purchase` time —
/// the sale verifies it. `max_amount` is the per-entry payment cap;
/// pass 0 for "no per-entry cap" (the sale's own per-buyer cap, if any,
/// still applies).
public fun new_entry<S>(admin: &AllowlistAdmin<S>, buyer: address, max_amount: u64): AllowEntry<S> {
    AllowEntry<S> {
        sale_id: admin.sale_id,
        buyer,
        max_amount,
    }
}

// === Library-internal: sale consumes entries ===

/// Consume an entry. Aborts if the entry was minted for a different sale
/// or different buyer. Returns `max_amount` so the sale can apply its
/// per-entry cap check.
///
/// Only `prefunded_sale::purchase` calls this.
public(package) fun consume<S>(
    entry: AllowEntry<S>,
    expected_sale_id: ID,
    expected_buyer: address,
): u64 {
    let AllowEntry { sale_id, buyer, max_amount } = entry;
    assert!(sale_id == expected_sale_id, EWrongSaleId);
    assert!(buyer == expected_buyer, EWrongBuyer);
    max_amount
}

// === Views ===

public fun admin_sale_id<S>(admin: &AllowlistAdmin<S>): ID { admin.sale_id }
