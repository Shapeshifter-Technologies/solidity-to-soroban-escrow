#![cfg(test)]

use super::*;
use soroban_sdk::{
    symbol_short,
    testutils::{Address as _, Ledger},
    token, Address, Env, Symbol,
};

fn setup(env: &Env) -> (EscrowContractClient<'_>, Address, Address, Address, Address) {
    let admin = Address::generate(env);
    let depositor = Address::generate(env);
    let beneficiary = Address::generate(env);

    let token_id = env.register(MockToken, ());
    let escrow_id = env.register(EscrowContract, ());
    let escrow_client = EscrowContractClient::new(env, &escrow_id);

    env.mock_all_auths();

    MockTokenClient::new(env, &token_id).mint(&depositor, &1_000_000_i128);
    escrow_client.initialize(&admin);

    let now = 1000u64;
    env.ledger().set_timestamp(now);
    escrow_client.push_price(&2000_i128, &now);

    (escrow_client, token_id, admin, depositor, beneficiary)
}

// ═══════════════════════════════════════
// Mock Token
// ═══════════════════════════════════════

const BALANCE: Symbol = symbol_short!("balance");

#[contract(crate_path = "soroban_sdk")]
pub struct MockToken;

#[contractimpl(crate_path = "soroban_sdk")]
impl MockToken {
    pub fn mint(env: Env, to: Address, amount: i128) {
        let key = (BALANCE, to);
        let balance: i128 = env.storage().persistent().get(&key).unwrap_or(0);
        env.storage().persistent().set(&key, &(balance + amount));
    }

    pub fn balance(env: Env, id: Address) -> i128 {
        let key = (BALANCE, id);
        env.storage().persistent().get(&key).unwrap_or(0)
    }

    pub fn transfer(env: Env, from: Address, to: soroban_sdk::MuxedAddress, amount: i128) {
        from.require_auth();
        let from_balance = Self::balance(env.clone(), from.clone());
        assert!(from_balance >= amount, "insufficient balance");
        let to_addr = to.address();
        let to_balance = Self::balance(env.clone(), to_addr.clone());
        env.storage()
            .persistent()
            .set(&(BALANCE, from), &(from_balance - amount));
        env.storage()
            .persistent()
            .set(&(BALANCE, to_addr), &(to_balance + amount));
    }
}

// ═══════════════════════════════════════
// Tests
// ═══════════════════════════════════════

#[test]
fn test_initialize_and_version() {
    let env = Env::default();
    let admin = Address::generate(&env);
    let escrow_id = env.register(EscrowContract, ());
    env.mock_all_auths();

    let client = EscrowContractClient::new(&env, &escrow_id);
    client.initialize(&admin);

    assert_eq!(client.version(), 1);
    assert_eq!(client.admin(), admin);
}

#[test]
#[should_panic(expected = "already initialized")]
fn test_double_initialize_fails() {
    let env = Env::default();
    let admin = Address::generate(&env);
    let escrow_id = env.register(EscrowContract, ());
    env.mock_all_auths();

    let client = EscrowContractClient::new(&env, &escrow_id);
    client.initialize(&admin);
    client.initialize(&admin);
}

#[test]
fn test_create_escrow_and_get_info() {
    let env = Env::default();
    let (client, token_id, _admin, depositor, beneficiary) = setup(&env);

    let amount = 100_000_i128;
    let target_price = 2000_i128;
    let duration_ledgers = 1000u32;

    let id = client.create_escrow(
        &depositor,
        &beneficiary,
        &token_id,
        &amount,
        &target_price,
        &duration_ledgers,
    );

    assert_eq!(id, 0);
    let info = client.get_escrow_info(&id);
    assert_eq!(info.depositor, depositor);
    assert_eq!(info.beneficiary, beneficiary);
    assert_eq!(info.amount, amount);
    assert_eq!(info.target_price, target_price);
    assert_eq!(info.status, EscrowStatus::Funded);
}

#[test]
fn test_release_when_price_met() {
    let env = Env::default();
    let (client, token_id, _admin, depositor, beneficiary) = setup(&env);

    let amount = 50_000_i128;
    let target_price = 2000_i128;
    let duration_ledgers = 1000u32;

    let id = client.create_escrow(
        &depositor,
        &beneficiary,
        &token_id,
        &amount,
        &target_price,
        &duration_ledgers,
    );

    let token_client = token::Client::new(&env, &token_id);
    assert_eq!(token_client.balance(&beneficiary), 0);

    client.release(&id);

    let info = client.get_escrow_info(&id);
    assert_eq!(info.status, EscrowStatus::Released);
    assert_eq!(token_client.balance(&beneficiary), amount);
    assert_eq!(token_client.balance(&client.address), 0);
}

#[test]
#[should_panic(expected = "price condition not met")]
fn test_release_fails_when_price_below_target() {
    let env = Env::default();
    let (client, token_id, _admin, depositor, beneficiary) = setup(&env);

    env.ledger().set_timestamp(2000u64);
    client.push_price(&500_i128, &2000u64);

    let amount = 50_000_i128;
    let target_price = 2000_i128;
    let duration_ledgers = 1000u32;

    let id = client.create_escrow(
        &depositor,
        &beneficiary,
        &token_id,
        &amount,
        &target_price,
        &duration_ledgers,
    );

    client.release(&id);
}

#[test]
fn test_reclaim_after_expiry() {
    let env = Env::default();
    let (client, token_id, _admin, depositor, beneficiary) = setup(&env);

    let amount = 30_000_i128;
    let target_price = 10_000_i128;
    let duration_ledgers = 10u32;

    let token_client = token::Client::new(&env, &token_id);
    let balance_before = token_client.balance(&depositor);

    let id = client.create_escrow(
        &depositor,
        &beneficiary,
        &token_id,
        &amount,
        &target_price,
        &duration_ledgers,
    );

    assert_eq!(token_client.balance(&depositor), balance_before - amount);

    env.ledger().set_sequence_number(20);
    client.reclaim(&id);

    let info = client.get_escrow_info(&id);
    assert_eq!(info.status, EscrowStatus::Expired);
    assert_eq!(token_client.balance(&depositor), balance_before);
    assert_eq!(token_client.balance(&beneficiary), 0);
}

#[test]
fn test_cancel_by_admin() {
    let env = Env::default();
    let (client, token_id, _admin, depositor, beneficiary) = setup(&env);

    let amount = 25_000_i128;
    let target_price = 2000_i128;
    let duration_ledgers = 1000u32;

    let token_client = token::Client::new(&env, &token_id);
    let balance_before = token_client.balance(&depositor);

    let id = client.create_escrow(
        &depositor,
        &beneficiary,
        &token_id,
        &amount,
        &target_price,
        &duration_ledgers,
    );

    assert_eq!(token_client.balance(&depositor), balance_before - amount);

    client.cancel(&id);

    let info = client.get_escrow_info(&id);
    assert_eq!(info.status, EscrowStatus::Cancelled);
    assert_eq!(token_client.balance(&depositor), balance_before);
}

#[test]
fn test_push_price_and_get_price() {
    let env = Env::default();
    let (client, _token_id, _admin, _depositor, _beneficiary) = setup(&env);

    let cached = client.get_price();
    assert_eq!(cached.price, 2000_i128);
    assert_eq!(cached.timestamp, 1000u64);
}

#[test]
#[should_panic(expected = "price data is stale")]
fn test_release_fails_with_stale_price() {
    let env = Env::default();
    let (client, token_id, _admin, depositor, beneficiary) = setup(&env);

    let id = client.create_escrow(
        &depositor,
        &beneficiary,
        &token_id,
        &50_000_i128,
        &2000_i128,
        &1000u32,
    );

    env.ledger().set_timestamp(1301u64);
    client.release(&id);
}

#[test]
fn test_set_price_max_age_extends_staleness_window() {
    let env = Env::default();
    let (client, token_id, _admin, depositor, beneficiary) = setup(&env);

    let id = client.create_escrow(
        &depositor,
        &beneficiary,
        &token_id,
        &50_000_i128,
        &2000_i128,
        &1000u32,
    );

    client.set_price_max_age(&600u64);
    env.ledger().set_timestamp(1301u64);
    client.release(&id);

    let info = client.get_escrow_info(&id);
    assert_eq!(info.status, EscrowStatus::Released);
}
