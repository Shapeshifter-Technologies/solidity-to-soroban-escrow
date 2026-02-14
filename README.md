# From Solidity to Soroban: Escrow Smart Contract

A price-triggered escrow smart contract implemented in both **Solidity** and **Soroban (Rust)**, built as a companion to the article and video **"From Solidity to Soroban: Build an Escrow Smart Contract on Stellar."**

> **Article:** [From Solidity to Soroban](#) <!-- TODO: replace with Medium URL -->
>
> **Video:** [YouTube](#) <!-- TODO: replace with YouTube URL -->

## What This Is

A working escrow where:

- A depositor locks XLM (via the Stellar Asset Contract)
- An admin pushes a target price
- The contract releases funds to a beneficiary when XLM hits the target
- A time-based expiry returns funds if the price never triggers

This is a **teaching contract**, not production code. See the article for what's intentionally missing and why.

## Key Concepts Covered

| Solidity | Soroban |
|---|---|
| `msg.sender` | `caller.require_auth()` |
| `msg.value` | `token::Client::new().transfer()` |
| `require(cond)` | `assert!(cond)` |
| `mapping(uint => T)` | `env.storage().persistent().set()` |
| `onlyOwner` modifier | `require_admin()` helper |
| `constructor()` | `initialize()` + double-init guard |
| `emit Event(...)` | `env.events().publish()` |
| UUPS `upgradeTo()` | `env.deployer().update_current_contract_wasm()` |

## Prerequisites

### Soroban (Rust)
- [Rust](https://www.rust-lang.org/tools/install)
- `wasm32-unknown-unknown` target: `rustup target add wasm32-unknown-unknown`
- [Stellar CLI](https://soroban.stellar.org/docs/getting-started/setup)

### Solidity
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

## Soroban — Build & Test

```bash
stellar contract build
cargo test -p escrow
```

Or using the Makefile:

```bash
cd contracts/escrow
make test
```

### Deploy (Testnet)

```bash
stellar contract deploy \
  --wasm target/wasm32-unknown-unknown/release/escrow.wasm \
  --network testnet

stellar contract invoke --id <CONTRACT_ID> --network testnet \
  -- initialize --admin <YOUR_ADDRESS>
```

## Solidity — Build & Test

```bash
cd solidity
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std
forge build
forge test
```

## Project Structure

```
.
├── contracts/                      # Soroban (Rust)
│   └── escrow/
│       ├── Cargo.toml
│       ├── Makefile
│       └── src/
│           ├── lib.rs              # Contract implementation
│           └── test.rs             # Tests with mock token
├── solidity/                       # Solidity (Foundry)
│   ├── foundry.toml
│   ├── src/
│   │   └── Escrow.sol              # Equivalent contract
│   └── test/
│       └── Escrow.t.sol            # Foundry tests
├── Cargo.toml                      # Rust workspace root
└── README.md
```

## License

[MIT](LICENSE)
