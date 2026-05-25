/// Scenario walkthrough: soft-cap miss with refund vault.
#[test_only]
module sales_example::refund_path_tests;

use sales_example::fixed_rate_curve::{Self, FixedRateCurve};
use sales_example::prefunded_sale::{Self, PrefundedSale, SaleAdminCap};
use sales_example::refund_vault::{Self, RefundVault};
use sales_example::sale::Receipt;
use sales_example::my_token::{Self, MY_TOKEN};
use sales_example::sale_factory;
use sales_example::simple_kyc::{Self, KycModule, KycAdminCap};

use sui::clock;
use sui::coin::{Self, TreasuryCap};
use sui::sui::SUI;
use sui::test_scenario;

const ISSUER: address = @0xA11CE;
const TREASURY: address = @0xBEEF;
const ANYONE: address = @0xCAFE;
const BUYER_1: address = @0xB001;

const OPENS_AT: u64 = 1_000;
const CLOSES_AT: u64 = 10_000;
const SETUP_AT: u64 = 500;

const RATE: u64 = 100;
const HARD_CAP: u64 = 5_000;
const SOFT_CAP: u64 = 2_000;
const PER_BUYER_CAP: u64 = 3_000;
const INVENTORY: u64 = HARD_CAP * RATE;
const PER_ENTRY_CAP: u64 = 1_000;

#[test]
fun strategic_round_soft_cap_miss_refund() {
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

        let (s_id, _v_id) = sale_factory::deploy_strategic_round(
            &mut treasury_cap, &mut kyc, &kyc_cap, TREASURY,
            RATE, INVENTORY, HARD_CAP, SOFT_CAP, PER_BUYER_CAP,
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
        clock.set_for_testing(2_000);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(500, scenario.ctx());
        let quote = fixed_rate_curve::quote(&sale, 500);
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
        clock.set_for_testing(11_000);

        prefunded_sale::cancel_after_close(&mut sale, &mut vault, &clock, scenario.ctx());

        assert!(refund_vault::is_refunding(&vault), 0);
        assert!(refund_vault::value(&vault) == 500, 1);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(BUYER_1);

    {
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();

        let refunded = prefunded_sale::refund(&mut sale, &mut vault, receipt, scenario.ctx());

        assert!(coin::value(&refunded) == 500, 2);
        assert!(refund_vault::value(&vault) == 0, 3);

        transfer::public_transfer(refunded, BUYER_1);
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(TREASURY);

    {
        let mut sale = scenario.take_shared<PrefundedSale<FixedRateCurve, MY_TOKEN, SUI>>();
        let admin_cap = scenario.take_from_sender<SaleAdminCap<MY_TOKEN, SUI>>();

        let unsold = prefunded_sale::withdraw_unsold_inventory(
            &mut sale, &admin_cap, scenario.ctx(),
        );
        assert!(coin::value(&unsold) == INVENTORY, 4);

        transfer::public_transfer(unsold, TREASURY);
        scenario.return_to_sender(admin_cap);
        test_scenario::return_shared(sale);
    };

    test_scenario::end(scenario);
}
