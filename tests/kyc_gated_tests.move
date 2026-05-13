/// Scenario walkthroughs: KYC-gated strategic round.
///
/// Three tests:
///
///   1. `kyc_gated_purchase_and_claim` — happy path. Verified buyer
///      mints an `AllowEntry<MY_TOKEN>` in the same PTB as `purchase`,
///      the sale finalises successfully (soft cap met), buyer claims.
///
///   2. `unverified_buyer_cannot_mint_entry` — misuse rejection. An
///      unverified buyer cannot bypass compliance: `mint_entry` aborts
///      before reaching the sale.
///
///   3. `attacker_cannot_claim_buyers_receipt` — misuse rejection.
///      Even if an attacker gets access to the buyer's receipt object
///      (here through `take_from_address` shenanigans test_scenario
///      allows; in real Sui this requires the buyer's signing key),
///      `claim` aborts because `ctx.sender() != receipt.buyer`.
///
/// `abort 0` sentinels follow the known-aborting calls in the
/// `expected_failure` tests so the type checker is satisfied on the
/// locally bound values.
#[test_only, allow(lint(abort_without_constant))]
module sales_example::kyc_gated_tests;

use sales_example::prefunded_sale::{Self, PrefundedSale};
use sales_example::refund_vault::RefundVault;
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
const VERIFIED_BUYER: address = @0xB001;
const UNVERIFIED_BUYER: address = @0xB002;
const ATTACKER: address = @0xB003;

const OPENS_AT: u64 = 1_000;
const CLOSES_AT: u64 = 10_000;
const SETUP_AT: u64 = 500;

const RATE: u64 = 100;
const HARD_CAP: u64 = 5_000;
const SOFT_CAP: u64 = 2_000;
const PER_BUYER_CAP: u64 = 3_000;
const INVENTORY: u64 = HARD_CAP * RATE;
const PER_ENTRY_CAP: u64 = 3_000;

// === Happy path ===

#[test]
fun kyc_gated_purchase_and_claim() {
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

    // Verify the buyer for this specific sale.
    {
        let mut kyc = scenario.take_shared<KycModule>();
        let kyc_cap = scenario.take_from_sender<KycAdminCap>();
        simple_kyc::verify_buyer(&mut kyc, &kyc_cap, VERIFIED_BUYER, sale_id, PER_ENTRY_CAP);
        scenario.return_to_sender(kyc_cap);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(VERIFIED_BUYER);

    // mint_entry + purchase in the same PTB.
    {
        let kyc = scenario.take_shared<KycModule>();
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(2_000);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(2_500, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::some(entry), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ISSUER);

    // Permissionless finalize after close. Vault transitions to Closed.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(11_000);

        assert!(prefunded_sale::has_reached_soft_cap(&sale), 0);
        prefunded_sale::finalize(&mut sale, &mut vault, &clock);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(VERIFIED_BUYER);

    // Buyer claims.
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();

        let claimed = prefunded_sale::claim(&mut sale, receipt, scenario.ctx());
        assert!(coin::value(&claimed) == 250_000, 1);

        transfer::public_transfer(claimed, VERIFIED_BUYER);
        test_scenario::return_shared(sale);
    };

    test_scenario::end(scenario);
}

// === Misuse 1: unverified buyer ===

#[test, expected_failure(abort_code = simple_kyc::ENotVerified)]
fun unverified_buyer_cannot_mint_entry() {
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
    scenario.next_tx(UNVERIFIED_BUYER);

    {
        let kyc = scenario.take_shared<KycModule>();
        // Aborts: UNVERIFIED_BUYER is not in the verified table.
        let _entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        abort 0
    }
}

// === Misuse 2: receipt cannot be claimed by a non-buyer ===

#[test, expected_failure(abort_code = prefunded_sale::EBuyerOnly)]
fun attacker_cannot_claim_buyers_receipt() {
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
        simple_kyc::verify_buyer(&mut kyc, &kyc_cap, VERIFIED_BUYER, sale_id, PER_ENTRY_CAP);
        scenario.return_to_sender(kyc_cap);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(VERIFIED_BUYER);

    // VERIFIED_BUYER purchases.
    {
        let kyc = scenario.take_shared<KycModule>();
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(2_000);

        let entry = simple_kyc::mint_entry(&kyc, sale_id, scenario.ctx());
        let payment = coin::mint_for_testing<SUI>(2_500, scenario.ctx());
        prefunded_sale::purchase<MY_TOKEN, SUI>(
            &mut sale, payment, option::some(entry), &clock, scenario.ctx(),
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(kyc);
    };
    scenario.next_tx(ISSUER);

    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let mut vault = scenario.take_shared<RefundVault<SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(11_000);
        prefunded_sale::finalize(&mut sale, &mut vault, &clock);
        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
        test_scenario::return_shared(vault);
    };
    scenario.next_tx(ATTACKER);

    // ATTACKER reaches into VERIFIED_BUYER's inventory and tries to claim.
    // Aborts: ctx.sender() (ATTACKER) != receipt.buyer (VERIFIED_BUYER).
    {
        let mut sale = scenario.take_shared<PrefundedSale<MY_TOKEN, SUI>>();
        let receipt = scenario.take_from_address<Receipt<MY_TOKEN>>(VERIFIED_BUYER);
        let _claimed = prefunded_sale::claim(&mut sale, receipt, scenario.ctx());
        abort 0
    }
}
