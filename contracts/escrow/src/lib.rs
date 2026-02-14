#![no_std]
use soroban_sdk::{
    contract, contractimpl, contracttype, token, Address, BytesN, Env, Symbol, symbol_short,
};

const ADMIN: Symbol = symbol_short!("ADMIN");
const VERSION: Symbol = symbol_short!("VERSION");
const CONTRACT_VERSION: u32 = 1;

#[contracttype]
#[derive(Clone, Debug, PartialEq)]
pub enum EscrowStatus {
    Funded,
    Released,
    Cancelled,
    Expired,
}

#[contracttype]
#[derive(Clone, Debug)]
pub struct Escrow {
    pub depositor: Address,
    pub beneficiary: Address,
    pub token: Address,
    pub amount: i128,
    pub status: EscrowStatus,
    pub target_price: i128,
    pub expiry_ledger: u32,
}

#[contracttype]
#[derive(Clone, Debug)]
pub struct CachedPrice {
    pub price: i128,
    pub timestamp: u64,
}

#[contracttype]
pub enum DataKey {
    Escrow(u64),
    EscrowCount,
    OraclePrice,
    PriceMaxAge,
}

#[contract]
pub struct EscrowContract;

#[contractimpl]
impl EscrowContract {
    // ════════════════════════════════════════
    // INITIALIZATION
    // ════════════════════════════════════════

    pub fn initialize(env: Env, admin: Address) {
        if env.storage().instance().has(&ADMIN) {
            panic!("already initialized");
        }

        admin.require_auth();

        env.storage().instance().set(&ADMIN, &admin);
        env.storage().instance().set(&VERSION, &CONTRACT_VERSION);

        env.storage()
            .persistent()
            .set(&DataKey::PriceMaxAge, &300u64);
        env.storage()
            .persistent()
            .set(&DataKey::EscrowCount, &0u64);
    }

    // ════════════════════════════════════════
    // ESCROW LIFECYCLE
    // ════════════════════════════════════════

    pub fn create_escrow(
        env: Env,
        depositor: Address,
        beneficiary: Address,
        token: Address,
        amount: i128,
        target_price: i128,
        duration_ledgers: u32,
    ) -> u64 {
        depositor.require_auth();

        assert!(amount > 0, "amount must be positive");
        assert!(target_price > 0, "target price must be positive");
        assert!(duration_ledgers > 0, "duration must be positive");

        let contract_address = env.current_contract_address();
        token::Client::new(&env, &token).transfer(
            &depositor,
            &contract_address,
            &amount,
        );

        let current_ledger = env.ledger().sequence();
        let expiry_ledger = current_ledger
            .checked_add(duration_ledgers)
            .expect("ledger overflow");

        let escrow = Escrow {
            depositor,
            beneficiary,
            token,
            amount,
            status: EscrowStatus::Funded,
            target_price,
            expiry_ledger,
        };

        let id = Self::next_id(&env);
        env.storage().persistent().set(&DataKey::Escrow(id), &escrow);

        env.events().publish(
            (symbol_short!("created"),),
            (id, escrow.amount, escrow.target_price),
        );

        id
    }

    pub fn release(env: Env, escrow_id: u64) {
        let mut escrow = Self::get_escrow(&env, escrow_id);

        assert!(
            escrow.status == EscrowStatus::Funded,
            "escrow not in funded state"
        );

        if env.ledger().sequence() > escrow.expiry_ledger {
            panic!("escrow expired, use reclaim()");
        }

        let cached = Self::get_cached_price(&env);
        let max_age = Self::get_price_max_age(&env);
        let current_ts = env.ledger().timestamp();

        assert!(
            current_ts.saturating_sub(cached.timestamp) <= max_age,
            "price data is stale"
        );

        assert!(
            cached.price >= escrow.target_price,
            "price condition not met"
        );

        token::Client::new(&env, &escrow.token).transfer(
            &env.current_contract_address(),
            &escrow.beneficiary,
            &escrow.amount,
        );

        escrow.status = EscrowStatus::Released;
        env.storage()
            .persistent()
            .set(&DataKey::Escrow(escrow_id), &escrow);

        env.events()
            .publish((symbol_short!("released"),), (escrow_id, cached.price));
    }

    pub fn reclaim(env: Env, escrow_id: u64) {
        let mut escrow = Self::get_escrow(&env, escrow_id);

        escrow.depositor.require_auth();

        assert!(
            escrow.status == EscrowStatus::Funded,
            "escrow not in funded state"
        );
        assert!(
            env.ledger().sequence() > escrow.expiry_ledger,
            "escrow has not expired"
        );

        token::Client::new(&env, &escrow.token).transfer(
            &env.current_contract_address(),
            &escrow.depositor,
            &escrow.amount,
        );

        escrow.status = EscrowStatus::Expired;
        env.storage()
            .persistent()
            .set(&DataKey::Escrow(escrow_id), &escrow);

        env.events().publish((symbol_short!("expired"),), (escrow_id,));
    }

    pub fn cancel(env: Env, escrow_id: u64) {
        let admin = Self::require_admin(&env);

        let mut escrow = Self::get_escrow(&env, escrow_id);
        assert!(
            escrow.status == EscrowStatus::Funded,
            "escrow not in funded state"
        );

        token::Client::new(&env, &escrow.token).transfer(
            &env.current_contract_address(),
            &escrow.depositor,
            &escrow.amount,
        );

        escrow.status = EscrowStatus::Cancelled;
        env.storage()
            .persistent()
            .set(&DataKey::Escrow(escrow_id), &escrow);

        env.events()
            .publish((symbol_short!("cancel"),), (escrow_id, admin));
    }

    // ════════════════════════════════════════
    // ORACLE CACHE
    // ════════════════════════════════════════

    pub fn push_price(env: Env, price: i128, timestamp: u64) {
        let _admin = Self::require_admin(&env);

        assert!(price > 0, "price must be positive");

        if let Some(existing) = Self::try_get_cached_price(&env) {
            assert!(
                timestamp >= existing.timestamp,
                "cannot push older price"
            );
        }

        let ledger_ts = env.ledger().timestamp();
        assert!(
            timestamp <= ledger_ts.checked_add(60).unwrap_or(u64::MAX),
            "timestamp too far in future"
        );

        let cached = CachedPrice { price, timestamp };
        env.storage()
            .temporary()
            .set(&DataKey::OraclePrice, &cached);

        env.storage()
            .temporary()
            .extend_ttl(&DataKey::OraclePrice, 600, 720);

        env.events()
            .publish((symbol_short!("price"),), (price, timestamp));
    }

    // ════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ════════════════════════════════════════

    pub fn set_price_max_age(env: Env, max_age_secs: u64) {
        let _admin = Self::require_admin(&env);
        assert!(max_age_secs > 0, "max age must be positive");

        env.storage()
            .persistent()
            .set(&DataKey::PriceMaxAge, &max_age_secs);
    }

    pub fn set_admin(env: Env, new_admin: Address) {
        let _admin = Self::require_admin(&env);
        new_admin.require_auth();

        env.storage().instance().set(&ADMIN, &new_admin);

        env.events().publish((symbol_short!("adm_set"),), (new_admin,));
    }

    pub fn upgrade(env: Env, new_wasm_hash: BytesN<32>) {
        let _admin = Self::require_admin(&env);
        env.deployer().update_current_contract_wasm(new_wasm_hash);
    }

    // ════════════════════════════════════════
    // VIEW FUNCTIONS
    // ════════════════════════════════════════

    pub fn get_escrow_info(env: Env, escrow_id: u64) -> Escrow {
        Self::get_escrow(&env, escrow_id)
    }

    pub fn get_price(env: Env) -> CachedPrice {
        Self::get_cached_price(&env)
    }

    pub fn admin(env: Env) -> Address {
        env.storage()
            .instance()
            .get(&ADMIN)
            .expect("not initialized")
    }

    pub fn version(_env: Env) -> u32 {
        CONTRACT_VERSION
    }

    // ════════════════════════════════════════
    // INTERNALS
    // ════════════════════════════════════════

    fn require_admin(env: &Env) -> Address {
        let admin: Address = env
            .storage()
            .instance()
            .get(&ADMIN)
            .expect("not initialized");
        admin.require_auth();
        admin
    }

    fn get_escrow(env: &Env, id: u64) -> Escrow {
        env.storage()
            .persistent()
            .get(&DataKey::Escrow(id))
            .expect("escrow not found")
    }

    fn get_cached_price(env: &Env) -> CachedPrice {
        env.storage()
            .temporary()
            .get(&DataKey::OraclePrice)
            .expect("no price data, push a price first")
    }

    fn try_get_cached_price(env: &Env) -> Option<CachedPrice> {
        env.storage().temporary().get(&DataKey::OraclePrice)
    }

    fn get_price_max_age(env: &Env) -> u64 {
        env.storage()
            .persistent()
            .get(&DataKey::PriceMaxAge)
            .unwrap_or(300u64)
    }

    fn next_id(env: &Env) -> u64 {
        let id: u64 = env
            .storage()
            .persistent()
            .get(&DataKey::EscrowCount)
            .unwrap_or(0);
        let next = id.checked_add(1).expect("escrow counter overflow");
        env.storage()
            .persistent()
            .set(&DataKey::EscrowCount, &next);
        id
    }
}

mod test;
