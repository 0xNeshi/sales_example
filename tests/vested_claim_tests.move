/// Scenario walkthrough: strategic round (vested) followed by vested
/// distribution.
#[test_only, allow(lint(abort_without_constant))]
module sales_example::vested_claim_tests;

use sales_example::fixed_rate_curve::{Self, FixedRateCurve};
use sales_example::linear_curve::{Self, LinearCurve};
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

const OPENS_AT: u64 = 1_000;
const CLOSES_AT: u64 = 10_000;
const SETUP_AT: u64 = 500;
const PURCHASE_AT: u64 = 2_000;
const FINALIZE_AT: u64 = 11_000;

const VEST_START_MS: u64 = 11_000;
const VEST_CLIFF_MS: u64 = 6_000;
const VEST_DURATION_MS: u64 = 12_000;

const T_PRE_CLIFF: u64 = 13_000;
const T_MID_VEST: u64 = 20_000;
const T_POST_END: u64 = 25_000;

const RATE: u64 = 100;
const HARD_CAP: u64 = 5_000;
const SOFT_CAP: u64 = 2_000;
const PER_BUYER_CAP: u64 = 3_000;
const INVENTORY: u64 = HARD_CAP * RATE;
const PER_ENTRY_CAP: u64 = 3_000;

const PURCHASE_AMOUNT: u64 = 2_500;
const EXPECTED_ALLOCATION: u64 = PURCHASE_AMOUNT * RATE;

#[test]
fun strategic_round_vested_claim_releases_over_time() {
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
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(PURCHASE_AMOUNT, scenario.ctx());
        let quote = fixed_rate_curve::quote(&sale, PURCHASE_AMOUNT);
        prefunded_sale::purchase<FixedRateCurve, MY_TOKEN, SUI>(
            &mut sale, payment, quote, option::some(entry), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ANYONE);

    {
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(FINALIZE_AT);

        prefunded_sale::finalize(&mut sale, &mut vault, &clock);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(BUYER_1);

    {
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();

        let allocation = prefunded_sale::claim_into_vesting<FixedRateCurve, MY_TOKEN, SUI>(
            &mut sale,
            receipt,
            scenario.ctx(),
        );
        vested_claim::into_shared_wallet<MY_TOKEN>(allocation, scenario.ctx());

        test_scenario::return_shared(sale);
    };
    scenario.next_tx(ANYONE);

    // Pre-cliff: nothing should release.
    {
        let mut wallet = scenario.take_shared<VestingWallet<LinearCurve, MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(T_PRE_CLIFF);

        assert!(linear_curve::releasable(&wallet, &clock) == 0, 100);

        let v = linear_curve::vested(&wallet, &clock);
        vesting_wallet::release(&mut wallet, v, scenario.ctx());

        assert!(vesting_wallet::balance(&wallet) == EXPECTED_ALLOCATION, 101);
        assert!(vesting_wallet::released(&wallet) == 0, 102);

        clock.destroy_for_testing();
        test_scenario::return_shared(wallet);
    };

    scenario.next_tx(ANYONE);

    // Mid-vesting: 9_000ms / 12_000ms = 75% → 187_500.
    {
        let mut wallet = scenario.take_shared<VestingWallet<LinearCurve, MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(T_MID_VEST);

        assert!(linear_curve::vested_amount(&wallet, &clock) == 187_500, 200);
        assert!(linear_curve::releasable(&wallet, &clock) == 187_500, 201);

        let v = linear_curve::vested(&wallet, &clock);
        vesting_wallet::release(&mut wallet, v, scenario.ctx());

        assert!(vesting_wallet::released(&wallet) == 187_500, 202);
        assert!(vesting_wallet::balance(&wallet) == EXPECTED_ALLOCATION - 187_500, 203);

        clock.destroy_for_testing();
        test_scenario::return_shared(wallet);
    };
    scenario.next_tx(BUYER_1);

    {
        let payout = scenario.take_from_sender<Coin<MY_TOKEN>>();
        assert!(coin::value(&payout) == 187_500, 210);
        scenario.return_to_sender(payout);
    };
    scenario.next_tx(ANYONE);

    // Post-end: full balance vests.
    {
        let mut wallet = scenario.take_shared<VestingWallet<LinearCurve, MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(T_POST_END);

        assert!(linear_curve::vested_amount(&wallet, &clock) == EXPECTED_ALLOCATION, 300);
        assert!(linear_curve::releasable(&wallet, &clock) == EXPECTED_ALLOCATION - 187_500, 301);

        let v = linear_curve::vested(&wallet, &clock);
        vesting_wallet::release(&mut wallet, v, scenario.ctx());

        assert!(vesting_wallet::released(&wallet) == EXPECTED_ALLOCATION, 302);
        assert!(vesting_wallet::balance(&wallet) == 0, 303);

        clock.destroy_for_testing();
        test_scenario::return_shared(wallet);
    };
    scenario.next_tx(BUYER_1);

    {
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
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(PURCHASE_AMOUNT, scenario.ctx());
        let quote = fixed_rate_curve::quote(&sale, PURCHASE_AMOUNT);
        prefunded_sale::purchase<FixedRateCurve, MY_TOKEN, SUI>(
            &mut sale, payment, quote, option::some(entry), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ANYONE);

    {
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(FINALIZE_AT);
        prefunded_sale::finalize(&mut sale, &mut vault, &clock);
        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(BUYER_1);

    {
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();
        let _claimed = prefunded_sale::claim(&mut sale, receipt, scenario.ctx());
        abort 0
    }
}
