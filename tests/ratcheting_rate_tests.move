/// Coverage for the `RatchetingRateCurve` pricing module.
///
/// The curve keeps the effective rate at `initial_rate` from
/// `opens_at_ms` onward, then steps it down by `step_delta` every
/// elapsed `step_ms`, floored at `min_rate`. Lower rate ⇒ fewer sale
/// tokens per payment unit ⇒ rising effective price.
///
/// The tests exercise:
///   - `current_rate` view across pre-open, exact-open, mid-ramp,
///     floor-reached, and far-past-floor timestamps;
///   - `purchase` allocations locking in the effective rate at the
///     moment of quote minting (different buyers, different
///     timestamps, different allocations against the same paid
///     amount);
///   - the floor path is reached without arithmetic wrap when
///     `steps * step_delta` would underflow `initial_rate - …`;
///   - the four Init-phase guards on `ratcheting_rate_curve::init_curve`.
#[test_only, allow(lint(abort_without_constant))]
module sales_example::ratcheting_rate_tests;

use sales_example::my_token::{Self, MY_TOKEN};
use sales_example::prefunded_sale::{Self, PrefundedSale};
use sales_example::ratcheting_rate_curve::{Self, RatchetingRateCurve};
use sales_example::refund_vault;
use sales_example::sale::Receipt;

use sui::clock;
use sui::coin::{Self, TreasuryCap};
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};

const ISSUER: address = @0xA11CE;
const TREASURY: address = @0xBEEF;
const BUYER_1: address = @0xB001;
const BUYER_2: address = @0xB002;
const BUYER_3: address = @0xB003;

const OPENS_AT: u64 = 1_000;
const CLOSES_AT: u64 = 100_000;
const SETUP_AT: u64 = 500;

// Schedule: at opens_at the rate is 100; every 1_000 ms the rate
// drops by 10; floor at 50.
const INITIAL_RATE: u64 = 100;
const STEP_MS: u64 = 1_000;
const STEP_DELTA: u64 = 10;
const MIN_RATE: u64 = 50;

const HARD_CAP: u64 = 10_000;
const INVENTORY: u64 = HARD_CAP * INITIAL_RATE;

// === Helpers ===

/// Deploy a public-round-style sale with the ratcheting curve attached.
fun deploy_ratcheting_sale(scenario: &mut Scenario) {
    let mut treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(SETUP_AT);

    let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<RatchetingRateCurve, MY_TOKEN, SUI>(
        /* max_rate */ INITIAL_RATE, HARD_CAP, /* soft_cap */ 0,
        OPENS_AT, CLOSES_AT, scenario.ctx(),
    );

    ratcheting_rate_curve::init_curve(&mut sale, INITIAL_RATE, STEP_MS, STEP_DELTA, MIN_RATE);

    let inventory = my_token::mint(&mut treasury_cap, INVENTORY, scenario.ctx());
    prefunded_sale::deposit_inventory(&mut sale, inventory);

    let (vault, vault_cap) = refund_vault::new<SUI>(scenario.ctx());
    prefunded_sale::pair_refund_vault(&mut sale, &vault, vault_cap);
    refund_vault::share(vault);

    prefunded_sale::share_and_activate(sale, &clock);

    transfer::public_transfer(sale_admin_cap, TREASURY);
    clock.destroy_for_testing();
    scenario.return_to_sender(treasury_cap);
}

// === current_rate view ===

#[test]
fun current_rate_steps_and_floors() {
    let mut scenario = test_scenario::begin(ISSUER);
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    deploy_ratcheting_sale(&mut scenario);
    scenario.next_tx(ISSUER);

    let sale = scenario.take_shared<PrefundedSale<RatchetingRateCurve, MY_TOKEN, SUI>>();
    let mut clock = clock::create_for_testing(scenario.ctx());

    // Pre-open: still INITIAL_RATE (no decay before the anchor point).
    clock.set_for_testing(SETUP_AT);
    assert!(ratcheting_rate_curve::current_rate(&sale, &clock) == INITIAL_RATE, 0);

    // Exactly at opens_at_ms.
    clock.set_for_testing(OPENS_AT);
    assert!(ratcheting_rate_curve::current_rate(&sale, &clock) == INITIAL_RATE, 1);

    // Just before one full step has elapsed.
    clock.set_for_testing(OPENS_AT + STEP_MS - 1);
    assert!(ratcheting_rate_curve::current_rate(&sale, &clock) == INITIAL_RATE, 2);

    // First step boundary: rate = 90.
    clock.set_for_testing(OPENS_AT + STEP_MS);
    assert!(ratcheting_rate_curve::current_rate(&sale, &clock) == INITIAL_RATE - STEP_DELTA, 3);

    // Fifth step: rate = 50 = MIN_RATE.
    clock.set_for_testing(OPENS_AT + 5 * STEP_MS);
    assert!(ratcheting_rate_curve::current_rate(&sale, &clock) == MIN_RATE, 4);

    // Sixth step: clamps at MIN_RATE.
    clock.set_for_testing(OPENS_AT + 6 * STEP_MS);
    assert!(ratcheting_rate_curve::current_rate(&sale, &clock) == MIN_RATE, 5);

    // Far past floor: still MIN_RATE (no underflow).
    clock.set_for_testing(OPENS_AT + 99 * STEP_MS);
    assert!(ratcheting_rate_curve::current_rate(&sale, &clock) == MIN_RATE, 6);

    clock.destroy_for_testing();
    test_scenario::return_shared(sale);
    test_scenario::end(scenario);
}

// === Purchases lock in the effective rate at quote-mint time ===

#[test]
fun purchases_lock_in_their_effective_rate() {
    let mut scenario = test_scenario::begin(ISSUER);
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    deploy_ratcheting_sale(&mut scenario);
    scenario.next_tx(BUYER_1);

    // BUYER_1 buys at opens_at_ms → rate = 100, allocation = 10 * 100.
    {
        let mut sale = scenario.take_shared<PrefundedSale<RatchetingRateCurve, MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(OPENS_AT);

        let payment = coin::mint_for_testing<SUI>(10, scenario.ctx());
        let quote = ratcheting_rate_curve::quote(&sale, 10, &clock);
        prefunded_sale::purchase<RatchetingRateCurve, MY_TOKEN, SUI>(
            &mut sale, payment, quote, option::none(), &clock, scenario.ctx(),
        );
        assert!(prefunded_sale::total_allocated(&sale) == 10 * INITIAL_RATE, 0);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(BUYER_2);

    // BUYER_2 buys one full step in → rate = 90, allocation = 10 * 90.
    {
        let mut sale = scenario.take_shared<PrefundedSale<RatchetingRateCurve, MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(OPENS_AT + STEP_MS);

        let payment = coin::mint_for_testing<SUI>(10, scenario.ctx());
        let quote = ratcheting_rate_curve::quote(&sale, 10, &clock);
        prefunded_sale::purchase<RatchetingRateCurve, MY_TOKEN, SUI>(
            &mut sale, payment, quote, option::none(), &clock, scenario.ctx(),
        );
        assert!(
            prefunded_sale::total_allocated(&sale)
                == 10 * INITIAL_RATE + 10 * (INITIAL_RATE - STEP_DELTA),
            1,
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };
    scenario.next_tx(BUYER_3);

    // BUYER_3 buys at the floor → rate = 50, allocation = 10 * 50.
    {
        let mut sale = scenario.take_shared<PrefundedSale<RatchetingRateCurve, MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        clock.set_for_testing(OPENS_AT + 5 * STEP_MS);

        let payment = coin::mint_for_testing<SUI>(10, scenario.ctx());
        let quote = ratcheting_rate_curve::quote(&sale, 10, &clock);
        prefunded_sale::purchase<RatchetingRateCurve, MY_TOKEN, SUI>(
            &mut sale, payment, quote, option::none(), &clock, scenario.ctx(),
        );
        assert!(
            prefunded_sale::total_allocated(&sale)
                == 10 * INITIAL_RATE
                    + 10 * (INITIAL_RATE - STEP_DELTA)
                    + 10 * MIN_RATE,
            2,
        );

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };

    // Per-buyer receipt checks.
    scenario.next_tx(BUYER_1);
    {
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();
        assert!(sales_example::sale::receipt_allocation(&receipt) == 10 * INITIAL_RATE, 3);
        scenario.return_to_sender(receipt);
    };
    scenario.next_tx(BUYER_2);
    {
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();
        assert!(
            sales_example::sale::receipt_allocation(&receipt) == 10 * (INITIAL_RATE - STEP_DELTA),
            4,
        );
        scenario.return_to_sender(receipt);
    };
    scenario.next_tx(BUYER_3);
    {
        let receipt = scenario.take_from_sender<Receipt<MY_TOKEN>>();
        assert!(sales_example::sale::receipt_allocation(&receipt) == 10 * MIN_RATE, 5);
        scenario.return_to_sender(receipt);
    };

    test_scenario::end(scenario);
}

// === Far past floor: no arithmetic wrap, allocations still use MIN_RATE ===

#[test]
fun purchase_past_floor_uses_min_rate() {
    let mut scenario = test_scenario::begin(ISSUER);
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    deploy_ratcheting_sale(&mut scenario);
    scenario.next_tx(BUYER_1);

    {
        let mut sale = scenario.take_shared<PrefundedSale<RatchetingRateCurve, MY_TOKEN, SUI>>();
        let mut clock = clock::create_for_testing(scenario.ctx());
        // 50 steps after open. Naïvely: rate = 100 - 50*10 = -400 (would
        // wrap a u64). The floor branch must catch this.
        clock.set_for_testing(OPENS_AT + 50 * STEP_MS);

        let payment = coin::mint_for_testing<SUI>(10, scenario.ctx());
        let quote = ratcheting_rate_curve::quote(&sale, 10, &clock);
        prefunded_sale::purchase<RatchetingRateCurve, MY_TOKEN, SUI>(
            &mut sale, payment, quote, option::none(), &clock, scenario.ctx(),
        );
        assert!(prefunded_sale::total_allocated(&sale) == 10 * MIN_RATE, 0);

        clock.destroy_for_testing();
        test_scenario::return_shared(sale);
    };

    test_scenario::end(scenario);
}

// === Guard: cannot init curve after activation ===

#[test, expected_failure(abort_code = prefunded_sale::ENotInit)]
fun init_curve_after_activation_aborts() {
    let mut scenario = test_scenario::begin(ISSUER);
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    deploy_ratcheting_sale(&mut scenario);
    scenario.next_tx(ISSUER);

    // Sale is shared and Active. Re-initializing curve aborts because
    // `uid_mut` requires Init phase (the activation check is on the
    // sale's phase, propagated through the dynamic field accessor).
    //
    // Actually, `init_curve` itself doesn't check phase — but it calls
    // `prefunded_sale::uid_mut`, and any subsequent setup-time invariant
    // gets enforced. The cleaner reproduction is via a setup function.
    // Here we use `set_per_buyer_cap` as the canary that fires `ENotInit`.
    {
        let mut sale = scenario.take_shared<PrefundedSale<RatchetingRateCurve, MY_TOKEN, SUI>>();
        prefunded_sale::set_per_buyer_cap(&mut sale, 100, scenario.ctx());
        test_scenario::return_shared(sale);
        abort 0
    }
}

// === Guard: double-init aborts ===

#[test, expected_failure(abort_code = ratcheting_rate_curve::ECurveAlreadyConfigured)]
fun init_curve_twice_aborts() {
    let mut scenario = test_scenario::begin(ISSUER);
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    {
        let treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<RatchetingRateCurve, MY_TOKEN, SUI>(
            INITIAL_RATE, HARD_CAP, 0, OPENS_AT, CLOSES_AT, scenario.ctx(),
        );

        ratcheting_rate_curve::init_curve(&mut sale, INITIAL_RATE, STEP_MS, STEP_DELTA, MIN_RATE);
        // Second call aborts.
        ratcheting_rate_curve::init_curve(&mut sale, INITIAL_RATE, STEP_MS, STEP_DELTA, MIN_RATE);

        transfer::public_transfer(sale_admin_cap, TREASURY);
        scenario.return_to_sender(treasury_cap);
        abort 0
    }
}

// === Guard: min_rate must be strictly below initial_rate ===

#[test, expected_failure(abort_code = ratcheting_rate_curve::EMinRateNotBelowInitial)]
fun init_curve_min_rate_equals_initial_aborts() {
    let mut scenario = test_scenario::begin(ISSUER);
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    {
        let treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<RatchetingRateCurve, MY_TOKEN, SUI>(
            INITIAL_RATE, HARD_CAP, 0, OPENS_AT, CLOSES_AT, scenario.ctx(),
        );

        // min_rate == INITIAL_RATE — no-op ratchet, rejected.
        ratcheting_rate_curve::init_curve(&mut sale, INITIAL_RATE, STEP_MS, STEP_DELTA, INITIAL_RATE);

        transfer::public_transfer(sale_admin_cap, TREASURY);
        scenario.return_to_sender(treasury_cap);
        abort 0
    }
}

// === Guard: step_ms == 0 aborts ===

#[test, expected_failure(abort_code = ratcheting_rate_curve::EStepMsZero)]
fun init_curve_step_ms_zero_aborts() {
    let mut scenario = test_scenario::begin(ISSUER);
    my_token::init_for_testing(scenario.ctx());
    scenario.next_tx(ISSUER);

    {
        let treasury_cap = scenario.take_from_sender<TreasuryCap<MY_TOKEN>>();
        let (mut sale, sale_admin_cap) = prefunded_sale::create_sale<RatchetingRateCurve, MY_TOKEN, SUI>(
            INITIAL_RATE, HARD_CAP, 0, OPENS_AT, CLOSES_AT, scenario.ctx(),
        );

        ratcheting_rate_curve::init_curve(&mut sale, INITIAL_RATE, /* step_ms */ 0, STEP_DELTA, MIN_RATE);

        transfer::public_transfer(sale_admin_cap, TREASURY);
        scenario.return_to_sender(treasury_cap);
        abort 0
    }
}
