/// Scenario walkthrough: strategic round (vested) followed by vested
/// distribution.
///
/// The flow exercised:
///   - Issuer publishes MY_TOKEN, the KYC module, and a strategic
///     round configured with a vesting schedule.
///   - Issuer verifies BUYER_1 for the sale.
///   - BUYER_1 purchases 2_500 mist (above soft cap, sale succeeds).
///   - The window closes; anyone calls `finalize` permissionlessly.
///   - BUYER_1 calls `prefunded_sale::claim_into_vesting` and pipes the
///     returned `VestedAllocation<MY_TOKEN>` hot-potato directly into
///     `vested_claim::into_shared_wallet`. A shared vesting wallet is
///     created and funded with the buyer's allocation; the buyer
///     never sees a raw `Coin<MY_TOKEN>`.
///   - At three time points (pre-cliff, mid-vesting, post-end), anyone
///     calls `vesting_wallet::release`. The vested portion at each
///     point is transferred to BUYER_1.
///
/// Reading goal: see the buyer's redemption path on a vested sale.
/// The schedule lives on the sale (set during Init) and the library
/// refuses to let the buyer skip it — `prefunded_sale::claim` aborts
/// with `EClaimRequiresVesting`; the only route to the underlying
/// `Coin<MY_TOKEN>` is `claim_into_vesting` + a `vested_claim::into_*`
/// consumer, both of which live in the library.
#[test_only, allow(lint(abort_without_constant))]
module sales_example::vested_claim_tests;

use sales_example::my_token::{Self, MY_TOKEN};
use sales_example::prefunded_sale::{Self, PrefundedSale};
use sales_example::refund_vault::RefundVault;
use sales_example::sale::Receipt;
use sales_example::sale_factory;
use sales_example::simple_kyc::{Self, KycModule, KycAdminCap};
use sales_example::vested_claim;
use sales_example::vesting_wallet::{Self, VestingWallet};

use sui::clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::sui::SUI;
use sui::test_scenario;

const ISSUER: address = @0xA11CE;
const TREASURY: address = @0xBEEF;
const ANYONE: address = @0xCAFE;
const BUYER_1: address = @0xB001;

// Sale schedule (sale opens, sale closes).
const OPENS_AT: u64 = 1_000;
const CLOSES_AT: u64 = 10_000;
const SETUP_AT: u64 = 500;
const PURCHASE_AT: u64 = 2_000;
const FINALIZE_AT: u64 = 11_000;

// Vesting schedule — starts at sale close, 6-month cliff, 12-month total.
// Times are illustrative milliseconds, not realistic months.
const VEST_START_MS: u64 = 11_000;
const VEST_CLIFF_MS: u64 = 6_000;        // 6 of 12 "months"
const VEST_DURATION_MS: u64 = 12_000;

// Three observation points along the vesting curve.
const T_PRE_CLIFF: u64 = 13_000;         // 2_000 into the vest, still in cliff
const T_MID_VEST: u64 = 20_000;          // 9_000 into the vest, 75% vested linearly
const T_POST_END: u64 = 25_000;          // past start + duration; everything vested

const RATE: u64 = 100;
const HARD_CAP: u64 = 5_000;
const SOFT_CAP: u64 = 2_000;
const PER_BUYER_CAP: u64 = 3_000;
const INVENTORY: u64 = HARD_CAP * RATE;
const PER_ENTRY_CAP: u64 = 3_000;

const PURCHASE_AMOUNT: u64 = 2_500;
const EXPECTED_ALLOCATION: u64 = PURCHASE_AMOUNT * RATE;  // 250_000 MYT mist

#[test]
fun strategic_round_vested_claim_releases_over_time() {
    let mut scenario = test_scenario::begin(ISSUER);

    // Tx 1 — initialise token + KYC module.
    my_token::init_for_testing(scenario.ctx());
    let (_, _) = simple_kyc::deploy(scenario.ctx());
    scenario.next_tx(ISSUER);

    // Tx 2 — deploy strategic round.
    let sale_id;
    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut kyc = scenario.take_shared<KycModule>();
        let kyc_cap = scenario.take_from_sender<KycAdminCap>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);

        let (s_id, _v_id) = sale_factory::deploy_strategic_round_vested(
            &mut treasury_cap, &mut kyc, &kyc_cap, TREASURY,
            RATE, INVENTORY, HARD_CAP, SOFT_CAP, PER_BUYER_CAP,
            // Vesting policy is sale-defined: 6-month cliff,
            // 12-month linear from sale close (illustrative ms).
            VEST_START_MS, VEST_CLIFF_MS, VEST_DURATION_MS,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );
        sale_id = s_id;

        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
        scenario.return_to_sender(kyc_cap);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ISSUER);

    // Tx 3 — verify the buyer.
    {
        let mut kyc = scenario.take_shared<KycModule>();
        let kyc_cap = scenario.take_from_sender<KycAdminCap>();
        simple_kyc::verify_buyer(&mut kyc, &kyc_cap, BUYER_1, sale_id, PER_ENTRY_CAP);
        scenario.return_to_sender(kyc_cap);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(BUYER_1);

    // Tx 4 — buyer purchases enough to clear the soft cap.
    {
        let kyc = scenario.take_shared<KycModule>();
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(PURCHASE_AMOUNT, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::some(entry), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ANYONE);

    // Tx 5 — permissionless finalize.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(FINALIZE_AT);

        prefunded_sale::finalize(&mut sale, &mut vault, &clock);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(BUYER_1);

    // Tx 6 — buyer claims into a vested wallet (cliff + linear schedule).
    //
    // The library returns a `VestedAllocation<MY_TOKEN>` hot-potato
    // (no drop / key / store), so the only legal continuation in this
    // PTB is to pass it to a `vested_claim::into_*` consumer. The
    // buyer cannot peel the inner `Coin<MY_TOKEN>` out of the carrier.
    // The schedule is read from the sale by `claim_into_vesting`; the
    // buyer cannot supply or override it.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();

        let allocation = prefunded_sale::claim_into_vesting<MY_TOKEN, SUI>(
            &mut sale,
            receipt,
            scenario.ctx(),
        );
        vested_claim::into_shared_wallet<MY_TOKEN>(allocation, scenario.ctx());

        test_scenario::return_shared(sale);
    };
    scenario.next_tx(ANYONE);

    // Tx 7 — pre-cliff: anyone pokes release; nothing should pay out.
    // The buyer's MY_TOKEN inventory should be zero afterwards (no
    // release event, no coin transferred).
    {
        let mut wallet = scenario.take_shared<VestingWallet<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(T_PRE_CLIFF);

        // Sanity: pre-cliff vested = 0.
        assert!(vesting_wallet::releasable(&wallet, &clock) == 0, 100);

        vesting_wallet::release(&mut wallet, &clock, scenario.ctx());

        // Wallet still holds the full allocation.
        assert!(vesting_wallet::balance(&wallet) == EXPECTED_ALLOCATION, 101);
        assert!(vesting_wallet::released(&wallet) == 0, 102);

        clock.destroy_for_testing();
        test_scenario::return_shared(wallet);
    };

    // Buyer's inventory should be empty (no release happened).
    scenario.next_tx(BUYER_1);
    {
        // No Coin<MY_TOKEN> has been delivered yet, so take_from_sender
        // for that type would fail. We don't run it; the assertions
        // above already confirm the wallet is untouched.
    };
    scenario.next_tx(ANYONE);

    // Tx 8 — mid-vesting: 9_000ms elapsed of 12_000ms total = 75%.
    // 75% of 250_000 = 187_500 MYT vested. Buyer receives that amount.
    {
        let mut wallet = scenario.take_shared<VestingWallet<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(T_MID_VEST);

        // 9_000ms elapsed / 12_000ms duration = 75% of 250_000 = 187_500
        assert!(vesting_wallet::vested_amount(&wallet, &clock) == 187_500, 200);
        assert!(vesting_wallet::releasable(&wallet, &clock) == 187_500, 201);

        vesting_wallet::release(&mut wallet, &clock, scenario.ctx());

        assert!(vesting_wallet::released(&wallet) == 187_500, 202);
        assert!(vesting_wallet::balance(&wallet) == EXPECTED_ALLOCATION - 187_500, 203);

        clock.destroy_for_testing();
        test_scenario::return_shared(wallet);
    };
    scenario.next_tx(BUYER_1);

    // Buyer should now hold 187_500 MYT (split into one Coin object).
    {
        let payout = scenario.take_from_sender<Coin<MY_TOKEN>>();
        assert!(coin::value(&payout) == 187_500, 210);
        scenario.return_to_sender(payout);
    };
    scenario.next_tx(ANYONE);

    // Tx 9 — post-end: full balance vests; second release pays the rest.
    {
        let mut wallet = scenario.take_shared<VestingWallet<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(T_POST_END);

        assert!(vesting_wallet::vested_amount(&wallet, &clock) == EXPECTED_ALLOCATION, 300);
        assert!(vesting_wallet::releasable(&wallet, &clock) == EXPECTED_ALLOCATION - 187_500, 301);

        vesting_wallet::release(&mut wallet, &clock, scenario.ctx());

        assert!(vesting_wallet::released(&wallet) == EXPECTED_ALLOCATION, 302);
        assert!(vesting_wallet::balance(&wallet) == 0, 303);

        clock.destroy_for_testing();
        test_scenario::return_shared(wallet);
    };
    scenario.next_tx(BUYER_1);

    // Buyer now has TWO Coin<MY_TOKEN> objects in their inventory:
    // - the 187_500 from mid-vest
    // - the EXPECTED_ALLOCATION - 187_500 = 62_500 from post-end
    {
        // Just take both and assert. They're separate coin objects until
        // joined by the wallet.
        let payout1 = scenario.take_from_sender<Coin<MY_TOKEN>>();
        let payout2 = scenario.take_from_sender<Coin<MY_TOKEN>>();

        let total = coin::value(&payout1) + coin::value(&payout2);
        assert!(total == EXPECTED_ALLOCATION, 400);

        scenario.return_to_sender(payout1);
        scenario.return_to_sender(payout2);
    };

    test_scenario::end(scenario);
}

// === Regression: plain `claim` is unreachable on a vested sale ===

/// Verifies the P1 fix from review round 6: with a vesting schedule
/// attached, `prefunded_sale::claim` aborts. The buyer cannot bypass
/// vesting by calling the immediate-distribution path; the only legal
/// route is `claim_into_vesting` → a `vested_claim::into_*` consumer.
#[test, expected_failure(abort_code = prefunded_sale::EClaimRequiresVesting)]
fun plain_claim_aborts_on_vested_sale() {
    let mut scenario = test_scenario::begin(ISSUER);

    my_token::init_for_testing(scenario.ctx());
    let (_, _) = simple_kyc::deploy(scenario.ctx());
    scenario.next_tx(ISSUER);

    let sale_id;
    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut kyc = scenario.take_shared<KycModule>();
        let kyc_cap = scenario.take_from_sender<KycAdminCap>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);

        let (s_id, _v_id) = sale_factory::deploy_strategic_round_vested(
            &mut treasury_cap, &mut kyc, &kyc_cap, TREASURY,
            RATE, INVENTORY, HARD_CAP, SOFT_CAP, PER_BUYER_CAP,
            VEST_START_MS, VEST_CLIFF_MS, VEST_DURATION_MS,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );
        sale_id = s_id;

        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
        scenario.return_to_sender(kyc_cap);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ISSUER);

    {
        let mut kyc = scenario.take_shared<KycModule>();
        let kyc_cap = scenario.take_from_sender<KycAdminCap>();
        simple_kyc::verify_buyer(&mut kyc, &kyc_cap, BUYER_1, sale_id, PER_ENTRY_CAP);
        scenario.return_to_sender(kyc_cap);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(BUYER_1);

    {
        let kyc = scenario.take_shared<KycModule>();
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(PURCHASE_AMOUNT, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::some(entry), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ANYONE);

    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(FINALIZE_AT);
        prefunded_sale::finalize(&mut sale, &mut vault, &clock);
        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(BUYER_1);

    // Buyer attempts the plain claim path. Aborts: EClaimRequiresVesting.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();
        let _claimed = prefunded_sale::claim(&mut sale, receipt, scenario.ctx());
        abort 0
    }
}
