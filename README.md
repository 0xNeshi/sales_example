# `sales_example` — Token Pre-Sale Standard, integration walkthrough

A single Move package that demonstrates the proposed `openzeppelin_sales`
v1 standard alongside example integrator code.

The package is split into two directories under `sources/`:

- **`library/`** — the audit-boundary modules. When the design is
  locked, these get extracted to their own package at
  `contracts/sales/` and renamed under the `openzeppelin_sales`
  address.
- **`integration/`** — example integrator code that consumes the
  library. These would not be part of the audited library; they ship
  as reference configurations (Tier 2).

### Boundary discipline

In a single-package layout the type system cannot enforce the
library/integration boundary: `public(package)` symbols are visible
across `sources/library/` and `sources/integration/`. **The convention
is: integration code never calls a library `public(package)` function.**
Library-internal helpers (`sale::new_receipt`,
`sale::deliver_receipt`, `sale::consume_receipt`,
`sale::new_vested_allocation`, `sale::unpack_vested_allocation`,
`allowlist::new_admin`, `allowlist::consume`, all the `sale::phase_*`
factories) exist for sibling library modules only. The integration
modules in this example respect that convention; once the library
extracts to its own package, the boundary becomes type-enforced.

If you copy this layout into your own work, lint or grep for
`public(package)` calls originating from `sources/integration/` —
that is the easy enforcement mechanism. Treat such a call as a
boundary violation.

**Not for deployment.** Illustrative code for design review.

## What this primitive is — and is not

The library implements **fixed-price token sales** with caps, an
optional allowlist hook, and refundable escrow. It does **not** do:

- Bonding curves, dynamic-bonding-curve fair launches, or any
  price-discovery mechanism (different primitive — see pump.fun,
  Metaplex Genesis Launch Pool, Sui Memez.gg for that family).
- Dutch / English / sealed-bid / uniform-price auctions.
- Mint-on-purchase from a `TreasuryCap<S>` held in the contract
  (v2 will ship `MintingSale<S, P>` as a parallel sale flavor).

Reach for a different primitive if those are what you need.

## Layout

```
sales_example/
├── Move.toml                            [package] name = "sales_example"
├── README.md                            ← you are here
├── sources/
│   ├── library/                         Tier-1 modules — what gets audited
│   │   ├── sale.move                    Phase, Receipt<S>, VestingSchedule,
│   │   │                                VestedAllocation<S> hot potato
│   │   ├── prefunded_sale.move          PrefundedSale<S, P> + lifecycle + claim paths
│   │   ├── refund_vault.move            Generic refundable escrow over Balance<P>
│   │   ├── allowlist.move               AllowEntry<S> hot potato + AllowlistAdmin<S>
│   │   ├── vesting_wallet.move          Linear vesting wallet (vendored, modified)
│   │   └── vested_claim.move            VestedAllocation<S> → VestingWallet<S> consumers
│   └── integration/                     Tier-2 modules — integrator-owned
│       ├── my_token.move                Sample sale token
│       ├── simple_kyc.move              Compliance module: per-sale verified list
│       └── sale_factory.move            Domain-named deploy helpers
└── tests/                               Scenario walkthroughs (not coverage)
    ├── happy_path_tests.move            Public round → finalize → claim
    ├── refund_path_tests.move           Strategic round → soft-cap miss → refund
    ├── kyc_gated_tests.move             KYC happy path + 2 misuse rejections
    ├── capped_public_round_tests.move   Per-buyer cap + hard-cap early finalize +
    │                                    cancel_emergency guard branches
    └── vested_claim_tests.move          Strategic round (vested) → finalize →
                                         vested release + plain-claim-aborts regression
```

## Run

```sh
cd sales_example
sui move test
```

Expected output:

```
[ PASS ] sales_example::happy_path_tests::public_sale_happy_path
[ PASS ] sales_example::kyc_gated_tests::attacker_cannot_claim_buyers_receipt
[ PASS ] sales_example::kyc_gated_tests::kyc_gated_purchase_and_claim
[ PASS ] sales_example::kyc_gated_tests::unverified_buyer_cannot_mint_entry
[ PASS ] sales_example::refund_path_tests::strategic_round_soft_cap_miss_refund
```

## Choosing a sale shape

Four orthogonal axes parameterise a sale. Configure by which factory
helper is called:

| Helper | KYC | Soft cap | Per-buyer cap | Vesting | Typical use |
|---|---|---|---|---|---|
| `deploy_public_round` | no | no | no | no | Open public sale, FCFS up to hard cap |
| `deploy_capped_public_round` | no | no | yes | no | Anti-whale public sale |
| `deploy_strategic_round` | yes | yes | yes | no | Compliance-gated raise, immediate distribution |
| `deploy_strategic_round_vested` | yes | yes | yes | yes | Compliance-gated raise, linear-with-cliff vesting |

Every shape pairs a `RefundVault<P>` even with `soft_cap == 0`: the
library requires a vault at activation, so `cancel_emergency` always
has a refund destination.

For the vested variant, `prefunded_sale::claim` aborts and the only
redemption route is `claim_into_vesting` →
`vested_claim::into_shared_wallet` (or `into_owned_wallet`). The
schedule is sale-attached at construction; the buyer cannot supply,
override, or skip it. See the "Vesting" section under "Known
limitations" for the residual constraints.

Shared characteristics enforced by the library:

- **Permissionless close.** Once `closes_at_ms` has passed, *anyone*
  can call `finalize` (success) or `cancel_after_close` (soft-cap
  miss). Buyer claims and refunds do not depend on admin liveness.
- **Hard cap required**, inventory at activation must cover
  `hard_cap * rate`. Sold-out and hard-cap-reached coincide.
- **Receipts are non-transferable.** `Receipt<S>` has `key` only.
  `claim` and `refund` assert `ctx.sender() == receipt.buyer`. Wallet
  rotation between purchase and redemption is not supported.
- **`finalize` synchronises the vault state** by flipping it to
  `Closed`. Indexers see matched terminal states.
- **Bounded emergency cancel.** Admin-only, in-window only, with
  `raised < hard_cap` and (`soft_cap == 0` or `raised < soft_cap`).
  Cannot rug a sale that has reached its goal.

## Key safety properties

1. **Typed vault caps.** `RefundVaultCap<P>` carries the
   payment-coin phantom: a cap from `RefundVault<USDC>` cannot be
   paired with a `PrefundedSale<_, SUI>`.
2. **Vault must be empty when paired.** `pair_refund_vault` asserts
   `value(vault) == 0`. Pre-existing funds would be stranded.
3. **Sender-bound claim and refund.** Even if someone obtained a
   receipt out-of-band, they cannot redeem it.
4. **Inventory backing enforced at activation.**
5. **Officer-set per-sale per-entry caps** in `simple_kyc`. Buyers
   cannot choose their own cap. `verify_buyer` requires the sale to
   be registered first.
6. **Sale-level cumulative per-buyer cap** is independent from the
   KYC per-entry cap. Configure via `set_per_buyer_cap`.
7. **U128-widened arithmetic on user input** for `raised + paid`,
   `contribution + paid`, and `paid * rate`.
8. **`set_per_buyer_cap` rejects zero.** A zero cap silently blocks
   every purchase.
9. **`enable_allowlist` is one-shot.** Prevents duplicate
   `AllowlistAdmin<S>` objects.

## Known limitations

- **Stale receipts pin inventory and refund funds. Production
  decision required.** The library is buyer-protective by default:
  a receipt that never gets claimed or refunded holds the underlying
  funds or inventory indefinitely.
  - In `Finalized`: an unclaimed receipt keeps its `allocation`
    pinned in `sale.inventory`. Admin can only ever withdraw the
    unallocated portion.
  - In `Cancelled`: an unrefunded receipt keeps its `paid` amount
    pinned in the vault's `locked` balance, and its `allocation`
    counted against `total_allocated`. The vault stays `Refunding`
    indefinitely.

  This is a deliberate v1 choice (no admin path can confiscate a
  buyer's position), and at the same time something every
  production deployer has to revisit. Common options:
  - **Accept the default.** Inventory and locked refund funds stay
    available for the buyer forever. Operationally cheap; the long
    tail of unclaimed positions is the cost.
  - **Add a grace-period sweep at the integration layer.** Wrap
    `claim` / `refund` in a module that, after a configurable grace
    period past `closes_at_ms`, lets a designated address sweep
    unclaimed allocations and unrefunded paid balances to a chosen
    destination (treasury, charity, on-chain pool). Requires its
    own audit; the library exposes no such sweep.
  - **Force pre-claim before close.** Use a sale flavor where
    delivery happens at purchase time and no receipt is issued.
    Sidesteps the question; gives up the
    soft-cap-refund + delayed-claim shape the prefunded sale
    relies on.

  v1 ships the first option. Decide before mainnet which one your
  partner's sale needs.
- **Vesting is library-enforced, end to end.** `VestingSchedule`
  (start / cliff / duration) lives in the library and is attached to
  the sale at `Init` via `set_vesting_schedule`. Once attached:
  - `prefunded_sale::claim` aborts with `EClaimRequiresVesting`. The
    only redemption path is `prefunded_sale::claim_into_vesting` →
    `vested_claim::into_shared_wallet` (or `into_owned_wallet`), both
    Tier-1.
  - `claim_into_vesting` returns a `VestedAllocation<S>` hot potato
    with no `drop`, `key`, or `store` ability and private fields. The
    only modules that can construct or unpack it are sibling library
    modules. A buyer cannot stash it, discard it, or extract the raw
    `Coin<S>` outside the library's defined consumer paths.
  - The schedule is **issuer-defined**: the buyer is the caller of
    redemption and cannot supply or override it.
  - The vendored wallet (`github.com/0xNeshi/vesting-wallet`) is
    Tier-1 with two recorded modifications: `migrate_beneficiary`
    removed (it let a verified buyer redirect future releases to an
    unverified address), and a `u128`-widened overflow check on
    `start_ms + duration_ms` at construction. Different wallet shapes
    (milestone, hybrid, clawback-capable) would be sibling library
    modules with their own audit story; v1 ships the linear-with-cliff
    shape only.
- **No anti-sniper beyond per-buyer cap.** A botnet defeats the cap
  by spreading across addresses. Tier-windowing using the allowlist
  hook is the planned mitigation; not yet shown as an example.
- **No `MintingSale<S, P>`.** Pre-funded only; v2 will add the
  mint-on-purchase flavor.
- **Rate is a single u64.** Sale tokens (smallest units) per
  1 payment smallest unit. Fractional rates require v2.
- **One `PaymentCoin` per sale.** Multi-payment is a deployment
  pattern (multiple sale objects), not a feature.
- **No library transfer function for receipts.** Wallet rotation
  between purchase and claim is not supported.

## Reading order

1. **`sources/library/sale.move`** — shared types
   (`Phase`, `Receipt<S>`, `VestingSchedule`, `VestedAllocation<S>`).
2. **`sources/library/prefunded_sale.move`** — the v1 sale flavor
   and the bulk of the design surface. The module doc walks the
   lifecycle and lists every integrator footgun.
3. **`sources/library/refund_vault.move`** — generic refundable
   escrow.
4. **`sources/library/allowlist.move`** — hot-potato compliance
   hook.
5. **`sources/library/vesting_wallet.move`** — linear-with-cliff
   wallet (vendored from `github.com/0xNeshi/vesting-wallet`,
   modified — see file header).
6. **`sources/library/vested_claim.move`** — the only consumer paths
   for `VestedAllocation<S>`; routes the carrier into a fresh
   `VestingWallet<S>`.
7. **`sources/integration/sale_factory.move`** — what wiring the
   four sale shapes looks like end to end.
8. **`sources/integration/simple_kyc.move`** — a realistic per-sale
   compliance module shape.
9. **`tests/`** — success, failure, vested-release, and
   misuse-rejection walkthroughs.

## What's not here yet

- `MintingSale<S, P>` (mint-on-purchase flavor) — v2.
- Tier-windowed allowlist example (anti-sniper for public rounds).
- Batch `verify_buyers` helper in `simple_kyc`.
- Increasing-price / decaying-price modules.
- Auctions, bonding-curve / fair-launch primitives — separate
  standards.
- Production-grade compliance verification (merkle proofs,
  accreditation tier ladders, jurisdiction filters) — `simple_kyc`
  is illustrative; partners replace it.
- TypeScript SDK, indexer schema reference, PTB builders.

## Next stage

This example exists to support iteration on the design before moving
to the Invariants stage. Open Questions in
`research/token-presale-standard/02-design.md § Open Questions` are
the next things to formalise.
