/// Example issuer-owned coin module.
///
/// The kind of `Coin` module an issuer already has — there is nothing
/// sale-specific here. The sales library never holds a
/// `TreasuryCap<MY_TOKEN>`; the issuer mints inventory off-band and
/// deposits the resulting `Coin<MY_TOKEN>` into the sale via the
/// sale flavor's `deposit_inventory`.
module sales_example::my_token;

use sui::coin::{Self, TreasuryCap};
use sui::url;

/// One-Time Witness. Type name must match the module name in uppercase.
public struct MY_TOKEN has drop {}

/// Module initializer. Creates the coin metadata and yields the
/// `TreasuryCap` to the publisher.
#[allow(deprecated_usage, lint(self_transfer))]
fun init(witness: MY_TOKEN, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency<MY_TOKEN>(
        witness,
        9, // decimals
        b"MYT",
        b"MyToken",
        b"Example sale token",
        option::some(url::new_unsafe_from_bytes(b"https://example.com/myt.png")),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, ctx.sender());
}

/// Publisher-only mint. The issuer calls this to produce inventory for
/// a sale, then deposits the resulting coin via `deposit_inventory`.
public fun mint(
    cap: &mut TreasuryCap<MY_TOKEN>,
    amount: u64,
    ctx: &mut TxContext,
): sui::coin::Coin<MY_TOKEN> {
    coin::mint<MY_TOKEN>(cap, amount, ctx)
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(MY_TOKEN {}, ctx)
}
