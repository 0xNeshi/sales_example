/// Capped-public-round and guard-branch coverage.
///
/// The previous suite exercised happy-path / refund-path / KYC flows
/// but left several behavioural branches in `prefunded_sale` untested:
///
///   - the sale-level cumulative `per_buyer_cap` actually blocks an
///     over-cap second purchase by the same buyer, while still letting
///     a different buyer continue;
///   - `finalize` is callable early once `raised >= hard_cap` even
///     before `closes_at_ms`;
///   - `cancel_emergency` aborts when the sale has already reached
///     `soft_cap` (guard against rugging a successful round);
///   - `cancel_emergency` aborts when `raised >= hard_cap` (guard
///     against cancelling a sold-out sale).
///
/// Each guard branch is an `expected_failure` test naming the exact
/// abort code, so the assertions in `prefunded_sale` are pinned down.
#[test_only, allow(lint(abort_without_constant))]
module sales_example::capped_public_round_tests;

use sales_example::my_token::{Self, MY_TOKEN};
use sales_example::prefunded_sale::{Self, PrefundedSale, SaleAdminCap};
use sales_example::refund_vault::RefundVault;
use sales_example::sale::Receipt;
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
const BUYER_2: address = @0xB002;

const OPENS_AT: u64 = 1_000;
const CLOSES_AT: u64 = 10_000;
const SETUP_AT: u64 = 500;
const PURCHASE_AT: u64 = 2_000;

const RATE: u64 = 100;
const HARD_CAP: u64 = 5_000;
const PER_BUYER_CAP: u64 = 1_000;
const INVENTORY: u64 = HARD_CAP * RATE;

// Used only by the soft-cap-met guard test (a strategic round).
const SOFT_CAP_FOR_STRATEGIC: u64 = 2_000;
const PER_BUYER_CAP_FOR_STRATEGIC: u64 = 3_000;
const PER_ENTRY_CAP_FOR_STRATEGIC: u64 = 3_000;

// === Capped public round — per-buyer cap enforces and is buyer-scoped ===

#[test]
fun capped_public_round_per_buyer_cap_blocks_one_buyer_not_another() {
    let mut scenario = test_scenario::begin(ISSUER);

    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    // Tx — deploy capped public round.
    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);

        let (_s, _v) = sale_factory::deploy_capped_public_round(
            &mut treasury_cap, TREASURY, RATE, INVENTORY, HARD_CAP, PER_BUYER_CAP,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
    };
    scenario.next_tx(BUYER_1);

    // BUYER_1 buys 600 mist — under cap; success.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let payment = coin::mint_for_testing<SUI>(600, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(BUYER_2);

    // BUYER_2 (independent address) buys 800 mist — under their own
    // per-buyer cap. The cap is per-address; BUYER_1's contribution
    // does not affect BUYER_2.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT + 1);

        let payment = coin::mint_for_testing<SUI>(800, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        // Both contributions counted on the sale's raised total.
        assert!(prefunded_sale::raised(&sale) == 1_400, 0);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };

    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = prefunded_sale::EPerBuyerCapExceeded)]
fun capped_public_round_second_buy_over_cap_aborts() {
    let mut scenario = test_scenario::begin(ISSUER);

    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);
        let (_s, _v) = sale_factory::deploy_capped_public_round(
            &mut treasury_cap, TREASURY, RATE, INVENTORY, HARD_CAP, PER_BUYER_CAP,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );
        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
    };
    scenario.next_tx(BUYER_1);

    // First purchase — 600 mist. Under per-buyer cap (1_000). OK.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let payment = coin::mint_for_testing<SUI>(600, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(BUYER_1);

    // Second purchase — 500 mist. Cumulative 1_100 > 1_000 cap. Aborts.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT + 1);

        let payment = coin::mint_for_testing<SUI>(500, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);

        abort 0
    }
}

// === Hard-cap reached → early finalize is allowed ===

#[test]
fun hard_cap_reached_allows_early_finalize() {
    let mut scenario = test_scenario::begin(ISSUER);

    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    // Deploy a public round so we can have several buyers hit the cap.
    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);
        let (_s, _v) = sale_factory::deploy_public_round(
            &mut treasury_cap, TREASURY, RATE, INVENTORY, HARD_CAP,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );
        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
    };
    scenario.next_tx(BUYER_1);

    // BUYER_1 takes the entire hard cap.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let payment = coin::mint_for_testing<SUI>(HARD_CAP, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        assert!(prefunded_sale::has_reached_hard_cap(&sale), 0);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(ANYONE);

    // ANYONE finalizes early, well before closes_at_ms. Allowed because
    // raised >= hard_cap.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        // Still inside the window — but hard cap is the trigger.
        clock.set_for_testing(PURCHASE_AT + 100);

        prefunded_sale::finalize(&mut sale, &mut vault, &clock);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(BUYER_1);

    // Buyer can claim immediately.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();
        let claimed = prefunded_sale::claim(&mut sale, receipt, scenario.ctx());
        assert!(coin::value(&claimed) == HARD_CAP * RATE, 1);
        transfer::public_transfer(claimed, BUYER_1);
        test_scenario::return_shared(sale);
    };

    test_scenario::end(scenario);
}

// === cancel_emergency guard: hard cap reached → abort ===

#[test, expected_failure(abort_code = prefunded_sale::ESaleAlreadyComplete)]
fun cancel_emergency_aborts_after_hard_cap_reached() {
    let mut scenario = test_scenario::begin(ISSUER);

    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);
        let (_s, _v) = sale_factory::deploy_public_round(
            &mut treasury_cap, TREASURY, RATE, INVENTORY, HARD_CAP,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );
        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
    };
    scenario.next_tx(BUYER_1);

    // Sell out.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let payment = coin::mint_for_testing<SUI>(HARD_CAP, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::none(), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(TREASURY);

    // Admin tries to emergency-cancel a sold-out sale. Aborts.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let admin_cap = scenario.take_from_sender<SaleAdminCap<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT + 1);

        prefunded_sale::cancel_emergency(
            &mut sale, &admin_cap, &mut vault, &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        scenario.return_to_sender(admin_cap);
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);

        abort 0
    }
}

// === cancel_emergency guard: soft cap reached → abort ===

#[test, expected_failure(abort_code = prefunded_sale::ESoftCapMet)]
fun cancel_emergency_aborts_after_soft_cap_met() {
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
            RATE, INVENTORY, HARD_CAP, SOFT_CAP_FOR_STRATEGIC, PER_BUYER_CAP_FOR_STRATEGIC,
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
        simple_kyc::verify_buyer(&mut kyc, &kyc_cap, BUYER_1, sale_id, PER_ENTRY_CAP_FOR_STRATEGIC);
        scenario.return_to_sender(kyc_cap);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(BUYER_1);

    // BUYER_1 hits the soft cap (2_500 > 2_000).
    {
        let kyc = scenario.take_shared<KycModule>();
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(2_500, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::some(entry), &clock, scenario.ctx(),
        );

        assert!(prefunded_sale::has_reached_soft_cap(&sale), 0);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(TREASURY);

    // Admin tries to emergency-cancel a sale that has met its soft cap.
    // Aborts: ESoftCapMet.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let admin_cap = scenario.take_from_sender<SaleAdminCap<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(PURCHASE_AT + 1);

        prefunded_sale::cancel_emergency(
            &mut sale, &admin_cap, &mut vault, &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        scenario.return_to_sender(admin_cap);
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);

        abort 0
    }
}

// === cancel_emergency guard: after close → abort ===

#[test, expected_failure(abort_code = prefunded_sale::EEmergencyCancelAfterClose)]
fun cancel_emergency_aborts_after_window_closes() {
    let mut scenario = test_scenario::begin(ISSUER);

    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    {
        let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(SETUP_AT);
        let (_s, _v) = sale_factory::deploy_public_round(
            &mut treasury_cap, TREASURY, RATE, INVENTORY, HARD_CAP,
            OPENS_AT, CLOSES_AT, &clock, scenario.ctx(),
        );
        clock.destroy_for_testing();
        scenario.return_to_sender(treasury_cap);
    };
    scenario.next_tx(TREASURY);

    // Admin tries to emergency-cancel after the window has closed.
    // The post-close path is permissionless `cancel_after_close` (for
    // soft-cap miss) or `finalize` (for success). `cancel_emergency`
    // is no longer reachable.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let admin_cap = scenario.take_from_sender<SaleAdminCap<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(CLOSES_AT + 1);

        prefunded_sale::cancel_emergency(
            &mut sale, &admin_cap, &mut vault, &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        scenario.return_to_sender(admin_cap);
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);

        abort 0
    }
}
