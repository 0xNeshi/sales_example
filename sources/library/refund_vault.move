/// Generic refundable escrow over `Balance<P>`. **No knowledge of sales.**
///
/// The vault is a standalone Tier-1 primitive — by design, it could be
/// extracted to its own package (`openzeppelin_escrow`) without an API
/// change. Per-address tracking lives in the *paired* sale (via the
/// `Receipt<S>` ticket) rather than in this vault, so the vault stays
/// generic.
///
/// State machine:
///   Active     → Refunding | Closed       (one-way, cap-gated)
///
/// The controller capability `RefundVaultCap<P>` is **typed on `P`** and
/// bound to a single vault (by `vault_id`). The phantom type prevents
/// pairing a cap from a `RefundVault<USDC>` with a sale that uses `SUI`
/// as its payment coin — type checking catches the mistake at compile
/// time rather than failing at cancel time.
///
/// Typical pairing: a `prefunded_sale::PrefundedSale<_, P>` consumes the
/// cap during `pair_refund_vault` and wraps it inside the sale's
/// lifecycle. From that moment on, no one but the sale's gated functions
/// can drive the vault — admin can't bypass the sale to drain the vault.
module sales_example::refund_vault;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

// === Errors ===

#[error(code = 0)]
const ENotActiveState: vector<u8> = "Vault must be in Active state";
#[error(code = 1)]
const ENotRefundingState: vector<u8> = "Vault must be in Refunding state";
#[error(code = 2)]
const ENotClosedState: vector<u8> = "Vault must be in Closed state";
#[error(code = 10)]
const EWrongVaultCap: vector<u8> = "Cap does not match this vault";
#[error(code = 20)]
const EInsufficientLocked: vector<u8> = "Release amount exceeds locked balance";

// === State ===

public enum VaultState has copy, drop, store {
    Active,
    Refunding,
    Closed,
}

public struct RefundVault<phantom P> has key {
    id: UID,
    locked: Balance<P>,
    state: VaultState,
}

/// Controller capability. Phantom-typed on `P` so it can only be paired
/// with vaults (and sales) of the matching payment coin.
public struct RefundVaultCap<phantom P> has key, store {
    id: UID,
    vault_id: ID,
}

// === Events ===

public struct RefundVaultCreated<phantom P> has copy, drop {
    vault_id: ID,
}

public struct VaultDeposit<phantom P> has copy, drop {
    vault_id: ID,
    amount: u64,
    locked_after: u64,
}

public struct VaultStateChanged<phantom P> has copy, drop {
    vault_id: ID,
    old_state: VaultState,
    new_state: VaultState,
}

public struct VaultRelease<phantom P> has copy, drop {
    vault_id: ID,
    amount: u64,
    locked_after: u64,
}

// === Constructor ===

/// Create a fresh vault in `Active` state. Returns the vault (caller
/// shares it) and the controller cap.
public fun new<P>(ctx: &mut TxContext): (RefundVault<P>, RefundVaultCap<P>) {
    let vault = RefundVault<P> {
        id: object::new(ctx),
        locked: balance::zero<P>(),
        state: VaultState::Active,
    };
    let vault_id = object::id(&vault);
    let cap = RefundVaultCap<P> { id: object::new(ctx), vault_id };
    event::emit(RefundVaultCreated<P> { vault_id });
    (vault, cap)
}

/// Share an existing vault. Provided here because `RefundVault<P>` has
/// `key` only (no `store`), so external modules cannot call
/// `transfer::public_share_object` on it directly. The typical pattern
/// is: `new` → `pair_refund_vault(&vault, cap)` → `share(vault)` in a
/// single PTB, so the sale can take the vault by reference before it
/// becomes shared.
public fun share<P>(vault: RefundVault<P>) {
    transfer::share_object(vault);
}

// === Cap-gated mutations ===

/// Cap-gated deposit. Vault must be in `Active` state.
public fun deposit<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>, funds: Balance<P>) {
    assert_cap(vault, cap);
    assert!(is_active_state(&vault.state), ENotActiveState);
    let amount = balance::value(&funds);
    balance::join(&mut vault.locked, funds);
    event::emit(VaultDeposit<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: balance::value(&vault.locked),
    });
}

/// Active → Refunding. Used by paired sale's `cancel_*`.
public fun flip_to_refunding<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert_cap(vault, cap);
    assert!(is_active_state(&vault.state), ENotActiveState);
    let old = vault.state;
    vault.state = VaultState::Refunding;
    event::emit(VaultStateChanged<P> {
        vault_id: object::id(vault),
        old_state: old,
        new_state: vault.state,
    });
}

/// Active → Closed. Available for vault-only flows where success means
/// the controller withdraws all (the paired-sale flow keeps proceeds in
/// the sale during Active and only routes to vault on cancel).
public fun flip_to_closed<P>(vault: &mut RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert_cap(vault, cap);
    assert!(is_active_state(&vault.state), ENotActiveState);
    let old = vault.state;
    vault.state = VaultState::Closed;
    event::emit(VaultStateChanged<P> {
        vault_id: object::id(vault),
        old_state: old,
        new_state: vault.state,
    });
}

/// Cap-gated targeted release. Vault must be in `Refunding`. Used by
/// paired sale's `refund` to pay back individual buyers from their receipts.
public fun release_balance<P>(
    vault: &mut RefundVault<P>,
    cap: &RefundVaultCap<P>,
    amount: u64,
): Balance<P> {
    assert_cap(vault, cap);
    assert!(is_refunding_state(&vault.state), ENotRefundingState);
    assert!(balance::value(&vault.locked) >= amount, EInsufficientLocked);
    let part = balance::split(&mut vault.locked, amount);
    event::emit(VaultRelease<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: balance::value(&vault.locked),
    });
    part
}

/// Cap-gated full withdrawal. Vault must be in `Closed`.
public fun withdraw_all<P>(
    vault: &mut RefundVault<P>,
    cap: &RefundVaultCap<P>,
    ctx: &mut TxContext,
): Coin<P> {
    assert_cap(vault, cap);
    assert!(is_closed_state(&vault.state), ENotClosedState);
    let amount = balance::value(&vault.locked);
    let part = balance::split(&mut vault.locked, amount);
    event::emit(VaultRelease<P> {
        vault_id: object::id(vault),
        amount,
        locked_after: 0,
    });
    coin::from_balance(part, ctx)
}

// === Views ===

public fun state<P>(vault: &RefundVault<P>): VaultState { vault.state }

/// Locked balance amount, in P's smallest units. Matches `coin::value` /
/// `balance::value` naming.
public fun value<P>(vault: &RefundVault<P>): u64 { balance::value(&vault.locked) }

public fun cap_vault_id<P>(cap: &RefundVaultCap<P>): ID { cap.vault_id }

public fun is_active<P>(vault: &RefundVault<P>): bool { is_active_state(&vault.state) }

public fun is_refunding<P>(vault: &RefundVault<P>): bool { is_refunding_state(&vault.state) }

public fun is_closed<P>(vault: &RefundVault<P>): bool { is_closed_state(&vault.state) }

// === Internal helpers ===

fun assert_cap<P>(vault: &RefundVault<P>, cap: &RefundVaultCap<P>) {
    assert!(cap.vault_id == object::id(vault), EWrongVaultCap);
}

fun is_active_state(s: &VaultState): bool {
    match (s) {
        VaultState::Active => true,
        _ => false,
    }
}

fun is_refunding_state(s: &VaultState): bool {
    match (s) {
        VaultState::Refunding => true,
        _ => false,
    }
}

fun is_closed_state(s: &VaultState): bool {
    match (s) {
        VaultState::Closed => true,
        _ => false,
    }
}
