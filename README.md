# `sales_example` — Token Pre-Sale Standard, integration walkthrough

A teaching package that demonstrates the proposed `openzeppelin_sales` v1
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
