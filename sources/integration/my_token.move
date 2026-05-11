/// Example sale-token published by an issuer. This is the kind of module
/// the integrator already has — a normal Sui `Coin` with its own
/// `TreasuryCap` flow. Nothing in this module touches `openzeppelin_sales`;
/// it just defines the asset that the sale will distribute.
///
/// In the v1 (`PrefundedSale`) flavor, the sale **never** holds the
/// `TreasuryCap<MY_TOKEN>`. The issuer mints the inventory off-band and
/// deposits the resulting `Coin<MY_TOKEN>` into the sale. In the future
/// v2 (`MintingSale`) flavor, the issuer would hand the `TreasuryCap`
/// to the sale instead.
module sales_example::my_token;

use sui::coin::{Self, TreasuryCap};
use sui::url;

/// One-Time Witness for the coin. Must match the module name in uppercase.
public struct MY_TOKEN has drop {}

/// Module initializer — runs exactly once when the package is published.
/// Creates the coin metadata and yields the `TreasuryCap` to the publisher.
#[allow(deprecated_usage, lint(self_transfer))]
fun init(witness: MY_TOKEN, ctx: &mut TxContext) {
    let (treasury, metadata) = coin::create_currency<MY_TOKEN>(
        witness,
        9, // decimals
        b"MYT", // symbol
        b"MyToken", // name
        b"Example sale token", // description
        option::some(url::new_unsafe_from_bytes(b"https://example.com/myt.png")),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury, ctx.sender());
}

/// Publisher-only mint. The issuer calls this to produce inventory for
/// the sale, then calls `prefunded_sale::deposit_inventory`.
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
