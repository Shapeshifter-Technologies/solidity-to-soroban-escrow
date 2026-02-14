default: build

all: test

test: build
	cargo test -p escrow

build:
	cargo build -p escrow --release
	@echo "WASM (if using stellar/soroban CLI): run from repo root: stellar contract build"

fmt:
	cargo fmt --all

clean:
	cargo clean
