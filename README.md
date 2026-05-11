# `sales_example` — Token Pre-Sale Standard, integration walkthrough

A teaching package that demonstrates the proposed `openzeppelin_sales` v1
shape from [`research/token-presale-standard/02-design.md`](../research/token-presale-standard/02-design.md).
It shows what the library would look like, how an integrator would adopt
it, and how end-to-end flows play out across multiple transactions.

**Not for deployment.** This is illustrative code for design review. Once
the design is locked, the library will be extracted to its own
audit-boundary package (`contracts/sales/`) and the integration sketches
will live as Tier-2 reference examples.

## Layout

```
sales_example/
├── Move.toml
├── README.md                            ← you are here
├── sources/
│   ├── library/                         ← Tier 1: the library proposal
│   │   ├── sale.move                    Phase enum, Receipt<S> (key-only), shared types
│   │   ├── prefunded_sale.move          PrefundedSale<S, P> + lifecycle
│   │   ├── refund_vault.move            Generic refundable escrow over Balance<P>
│   │   └── allowlist.move               AllowEntry<S> hot potato + AllowlistAdmin<S>
│   └── integration/                     ← Tier 2: integrator-owned code
│       ├── my_token.move                Sample sale token (issuer's MY_TOKEN)
│       ├── simple_kyc.move              Compliance module: per-sale verified list + admins
│       └── sale_factory.move            Domain-named deploy helpers
└── tests/                               ← Scenario walkthroughs (not coverage)
    ├── happy_path_tests.move            Public round → permissionless finalize → claim
    ├── refund_path_tests.move           Strategic round → permissionless cancel_after_close → refund
    └── kyc_gated_tests.move             KYC happy path + 2 misuse rejections
```

## Run

```sh
cd sales_example
sui move build
sui move test
```

Expected output:

```
[ PASS    ] sales_example::happy_path_tests::public_sale_happy_path
[ PASS    ] sales_example::kyc_gated_tests::attacker_cannot_claim_buyers_receipt
[ PASS    ] sales_example::kyc_gated_tests::kyc_gated_purchase_and_claim
[ PASS    ] sales_example::kyc_gated_tests::unverified_buyer_cannot_mint_entry
[ PASS    ] sales_example::refund_path_tests::strategic_round_soft_cap_miss_refund
```

## Tier-1 / Tier-2 boundary (single-package caveat)

In production, the audit-boundary library would live in a separate Move
package from integrator code. The library's `public(package)` helpers
would then be inaccessible to consumers — only sibling library modules
could call them.

**In this single-package example**, the following helpers are technically
reachable from `sources/integration/` because everything compiles into
the same Move package:

| Module | `public(package)` function | What could go wrong if integrator misused it |
|---|---|---|
| `sale.move` | `new_receipt` | Forge a receipt without going through `purchase` (no payment, no allowlist check) |
| `sale.move` | `deliver_receipt` | Deliver a forged receipt to any address |
| `sale.move` | `consume_receipt` | Destroy a receipt outside `claim`/`refund`, bypassing the phase guards |
| `allowlist.move` | `new_admin` | Forge an `AllowlistAdmin<S>` for any sale, bypassing `enable_allowlist` |
| `allowlist.move` | `consume` | Consume an `AllowEntry<S>` outside `purchase`, bypassing the sale's checks |

The integration code in this example does not call any of these. The
type system cannot enforce that today; when the library is extracted to
its own Move package, the boundary becomes real and reviewable.

This is a teaching-artifact limitation, called out so reviewers don't
mistake the package-internal surface for part of the public API.

## Key safety properties baked into v1

These were resolved across two rounds of review and are now reflected in
the code:

1. **Typed vault caps.** `RefundVaultCap<phantom P>` carries the
   payment-coin phantom, so a cap from `RefundVault<USDC>` cannot be
   paired with a `PrefundedSale<_, SUI>` — the type system rejects it
   at compile time.

2. **Vault must be empty when paired.** `pair_refund_vault` asserts
   `refund_vault::value(vault) == 0` along with the cap-binding and
   `Active`-state checks. Pre-existing funds in the vault would be
   stranded after finalize/cancel because the cap is wrapped into the
   sale and there's no library path to withdraw arbitrary vault funds.

3. **Receipts are non-transferable.** `Receipt<S>` has `key` only (no
   `store`). The only transfer path is `sale::deliver_receipt`, called
   by `purchase` to send the fresh receipt to its buyer. There is no
   library function to move a receipt afterward — it sits with the
   buyer until they `claim` or `refund`.

4. **Sender-bound claim and refund.** Both functions assert
   `ctx.sender() == receipt.buyer`. Combined with non-transferability,
   only the original buyer can ever consume their receipt.

5. **Permissionless close paths.** Once `closes_at_ms` passes (or hard
   cap is reached), anyone can call `finalize` (success) or
   `cancel_after_close` (soft-cap miss). Buyer claims and refunds **do
   not depend on admin liveness**. The admin cap only matters for
   `cancel_emergency` and proceeds/inventory withdrawal.

6. **`finalize` synchronizes vault state.** Takes the paired vault and
   flips it to `Closed` in the same call. Indexers see matched terminal
   states on both objects.

7. **Bounded `cancel_emergency`.** Admin-only, during Active only
   (`now <= closes_at_ms`), with `raised < hard_cap` *and*
   (`soft_cap == 0` or `raised < soft_cap`). Cannot rug a sale that has
   met its goal; cannot run after the permissionless paths take over.

8. **Inventory backing guaranteed at activation.** Every sale must have
   `inventory >= hard_cap * rate` before `share_and_activate` succeeds.
   Sold-out and hard-cap-reached coincide.

9. **Every sale gets a refund vault.** Activation requires a paired
   vault regardless of `soft_cap`, so `cancel_emergency` always has a
   refund destination.

10. **Officer-set per-sale per-entry caps.** In `simple_kyc`, the
    `verified` table is keyed by `(buyer, sale_id)` so multi-round
    campaigns can use different caps per round. Buyers cannot choose
    their own cap. `verify_buyer` asserts the sale is already registered
    so dead verification records can't be created by mistake.

11. **U128-widened arithmetic on user input.** `raised + paid`,
    `contribution + paid`, and `paid * rate` all use u128 widening with
    typed-error bounds checks. Malicious or oversized payments abort
    with a meaningful error rather than the default arithmetic overflow.

12. **`set_per_buyer_cap` rejects zero.** A zero per-buyer cap would
    silently block every purchase.

13. **`enable_allowlist` is one-shot.** Prevents issuing duplicate
    `AllowlistAdmin<S>` objects for the same sale.

## Known limitations / design choices

- **Stale receipts pin inventory *and* refund funds.** Buyer-protective
  by design; no grace-period sweep in v1.
  - In Finalized: an unclaimed receipt keeps its `allocation` pinned in
    `sale.inventory`. Admin can only ever withdraw the unallocated
    portion.
  - In Cancelled: an unrefunded receipt keeps its `paid` amount pinned
    in the vault's `locked` balance, *and* its `allocation` still counts
    against `total_allocated`. The vault stays `Refunding` indefinitely;
    `withdraw_all` requires `Closed`, which only `finalize` produces.
    Both the buyer's sale tokens and their payment stay locked until
    they call `refund`.
- **No clawback for vested tokens.** `claim_vested` (deferred from this
  example) integrates with Sui's canonical vesting wallets, which do
  not have clawback. Partners that need clawback bring their own wallet
  shape.
- **Rate is a single u64.** Fractional rates require v2.
- **One `PaymentCoin` per sale.** Multi-payment is a deployment pattern
  (multiple sale objects), not a feature of `PrefundedSale`.
- **`AllowlistAdmin<S>` is one-shot per sale.** `enable_allowlist`
  asserts idempotency.
- **No library transfer function for receipts.** Wallet rotation between
  purchase and claim is not supported by the library. Partners who need
  this build their own ticket type with appropriate compliance.

## Reading order

1. **`sources/library/sale.move`** — shared types (`Phase`, `Receipt<S>`).
2. **`sources/library/prefunded_sale.move`** — the v1 sale flavor and
   the bulk of the design surface. Module doc walks the lifecycle.
3. **`sources/library/refund_vault.move`** — generic escrow primitive.
4. **`sources/library/allowlist.move`** — hot-potato compliance hook.
5. **`sources/integration/sale_factory.move`** — see how an integrator
   wires everything up. Three flavors of `deploy_*` for different rounds.
6. **`sources/integration/simple_kyc.move`** — realistic compliance
   module with per-sale composite-key verification.
7. **`tests/`** — three scenario walkthroughs: success path, failure
   path with permissionless cancel-after-close, KYC happy path plus
   two misuse rejections (unverified buyer; attacker stealing a receipt).

## What's not here (yet)

Per the design doc's `Out of Scope` section:

- `MintingSale<S, P>` (mint-on-purchase flavor) — v2.
- `claim_vested` adapter into Sui canonical vesting wallets — defined in
  the design but not in this example yet.
- Increasing-price modules — separate price extension in v2.
- Auctions, bonding-curve fair launches, auto-LP — separate standards.
- Production-grade compliance verification — `simple_kyc` is illustrative.
- Receipt transfer / wallet-rotation flows — would require partner-owned
  ticket types with their own compliance.

## Next stage

This example exists to support iteration on the design before moving to
the Invariants stage of the skill workflow. Open Questions in
`02-design.md § Open Questions` are the next thing to formalize.
