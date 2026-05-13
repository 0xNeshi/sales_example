/// Scenario walkthrough: public round, no KYC, refund vault paired.
///
/// The flow exercised:
///   - Issuer deploys MY_TOKEN and a public sale.
///   - Two buyers purchase during the active window.
///   - A non-admin third party calls the permissionless `finalize`,
///     which transitions the paired vault to `Closed` in the same call.
///   - Buyers claim their tokens.
///   - Treasury (admin) withdraws proceeds and unsold inventory.
///
/// All numeric values are in **smallest units** (1 SUI = 10^9 mist).
/// The constants are intentionally small for arithmetic readability.
#[test_only]
module sales_example::happy_path_tests;

use sales_example::prefunded_sale::{Self, PrefundedSale, SaleAdminCap};
use sales_example::refund_vault::{Self, RefundVault};
use sales_example::sale::Receipt;
use sales_example::my_token::{Self, MY_TOKEN};
use sales_example::sale_factory;

use sui::clock;
use sui::coin::{Self, TreasuryCap};
use sui::sui::SUI;
use sui::test_scenario;

const ISSUER: address = @0xA11CE;
const TREASURY: address = @0xBEEF;
const ANYONE: address = @0xCAFE;
const BUYER_1: address = @0xB001;
const BUYER_2: address = @0xB002;

const OPENS_AT: u64 = 1_000;
const CLOSES_AT: u64 = 10_000;
const SETUP_AT: u64 = 500;

const RATE: u64 = 100;
const HARD_CAP: u64 = 5_000;
const INVENTORY: u64 = HARD_CAP * RATE;

#[test]
fun public_sale_happy_path() {
    let mut scenario = test_scenario::begin(ISSUER);

    // Tx 1 — issuer initialises MY_TOKEN, receives TreasuryCap.
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    // Tx 2 — issuer deploys the sale.
    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);
        let (_sale_id, _vault_id) = sale_factory::deploy_public_round(
            &mut treasury_cap, TREASURY, RATE, INVENTORY, HARD_CAP,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );
        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
    };
    scenario.next_tx(BUYER_1);

    // Tx 3 — buyer 1 purchases 1_000 mist at t=2_000.
    // The receipt is delivered to BUYER_1 by `purchase`.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(2_000);

        let payment = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(BUYER_2);

    // Tx 4 — buyer 2 purchases 2_500 mist at t=3_000.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(3_000);

        let payment = coin::mint_for_testing<SUI>(2_500, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        assert!(prefunded_sale::raised(&sale) == 3_500, 0);
        assert!(prefunded_sale::total_allocated(&sale) == 350_000, 1);
        assert!(prefunded_sale::inventory_remaining(&sale) == INVENTORY - 350_000, 2);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(ANYONE);

    // Tx 5 — ANYONE finalises (permissionless). Passes the paired vault;
    // the call transitions vault to Closed alongside the sale's Finalized.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(11_000);

        prefunded_sale::finalize(&mut sale, &mut vault, &clock);

        assert!(refund_vault::is_closed(&vault), 3);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(BUYER_1);

    // Tx 6 — buyer 1 claims.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();

        let claimed = prefunded_sale::claim(&mut sale, receipt, scenario.ctx());
        assert!(coin::value(&claimed) == 100_000, 4);

        transfer::public_transfer(claimed, BUYER_1);
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(BUYER_2);

    // Tx 7 — buyer 2 claims.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();

        let claimed = prefunded_sale::claim(&mut sale, receipt, scenario.ctx());
        assert!(coin::value(&claimed) == 250_000, 5);

        transfer::public_transfer(claimed, BUYER_2);
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(TREASURY);

    // Tx 8 — treasury withdraws proceeds and leftover inventory.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let admin_cap = scenario.take_from_sender<SaleAdminCap<MY_TOKEN, SUI>>();

        let proceeds = prefunded_sale::withdraw_proceeds(&mut sale, &admin_cap, scenario.ctx());
        assert!(coin::value(&proceeds) == 3_500, 6);

        let unsold = prefunded_sale::withdraw_unsold_inventory(&mut sale, &admin_cap, scenario.ctx());
        assert!(coin::value(&unsold) == INVENTORY - 350_000, 7);

        assert!(prefunded_sale::proceeds_amount(&sale) == 0, 8);
        assert!(prefunded_sale::inventory_total(&sale) == 0, 9);

        transfer::public_transfer(proceeds, TREASURY);
        transfer::public_transfer(unsold, TREASURY);

        scenario.return_to_sender(admin_cap);
        test_scenario::return_shared(sale);
    };

    test_scenario::end(scenario);
}
