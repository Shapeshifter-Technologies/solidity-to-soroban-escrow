// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title PriceEscrow
/// @notice Price-triggered escrow — the Solidity equivalent of the Soroban contract.
///         A depositor locks ERC-20 tokens. When an admin-pushed price meets the
///         target, anyone can release funds to the beneficiary. If the price never
///         triggers before expiry, the depositor reclaims their tokens.
/// @dev    Uses a push-oracle model for teaching purposes. See the article for
///         production alternatives (Chainlink, Redstone, etc.).
contract PriceEscrow is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ════════════════════════════════════════
    // TYPES
    // ════════════════════════════════════════

    enum EscrowStatus {
        Funded,
        Released,
        Cancelled,
        Expired
    }

    struct Escrow {
        address depositor;
        address beneficiary;
        IERC20 token;
        uint256 amount;
        EscrowStatus status;
        int256 targetPrice;
        uint256 expiryTimestamp;
    }

    struct CachedPrice {
        int256 price;
        uint256 timestamp;
    }

    // ════════════════════════════════════════
    // STATE
    // ════════════════════════════════════════

    mapping(uint256 => Escrow) public escrows;
    uint256 public escrowCount;

    CachedPrice public cachedPrice;
    uint256 public priceMaxAge = 300;

    // ════════════════════════════════════════
    // EVENTS
    // ════════════════════════════════════════

    event EscrowCreated(uint256 indexed escrowId, uint256 amount, int256 targetPrice);
    event EscrowReleased(uint256 indexed escrowId, int256 priceAtRelease);
    event EscrowExpired(uint256 indexed escrowId);
    event EscrowCancelled(uint256 indexed escrowId);
    event PricePushed(int256 price, uint256 timestamp);
    event PriceMaxAgeUpdated(uint256 maxAge);

    // ════════════════════════════════════════
    // ERRORS
    // ════════════════════════════════════════

    error AmountZero();
    error TargetPriceNotPositive();
    error DurationZero();
    error EscrowNotFunded(uint256 escrowId);
    error EscrowExpiredUseReclaim(uint256 escrowId);
    error EscrowNotExpired(uint256 escrowId);
    error PriceStale(uint256 age, uint256 maxAge);
    error PriceConditionNotMet(int256 current, int256 target);
    error PriceNotPositive();
    error TimestampOlderThanCached(uint256 provided, uint256 cached);
    error TimestampTooFarInFuture(uint256 provided, uint256 limit);
    error OnlyDepositor();
    error NoPriceData();

    // ════════════════════════════════════════
    // CONSTRUCTOR
    // ════════════════════════════════════════

    constructor(address admin_) Ownable(admin_) {}

    // ════════════════════════════════════════
    // ESCROW LIFECYCLE
    // ════════════════════════════════════════

    /// @notice Create and fund a new escrow.
    /// @dev    Caller must have approved this contract for `amount` of `token`.
    /// @param  beneficiary  Address that receives funds on release.
    /// @param  token        ERC-20 token to escrow.
    /// @param  amount       Token amount to lock.
    /// @param  targetPrice  Price threshold that triggers release.
    /// @param  duration     Seconds until the escrow expires.
    /// @return escrowId     The ID of the newly created escrow.
    function createEscrow(
        address beneficiary,
        IERC20 token,
        uint256 amount,
        int256 targetPrice,
        uint256 duration
    ) external nonReentrant returns (uint256 escrowId) {
        if (amount == 0) revert AmountZero();
        if (targetPrice <= 0) revert TargetPriceNotPositive();
        if (duration == 0) revert DurationZero();

        token.safeTransferFrom(msg.sender, address(this), amount);

        escrowId = escrowCount++;

        escrows[escrowId] = Escrow({
            depositor: msg.sender,
            beneficiary: beneficiary,
            token: token,
            amount: amount,
            status: EscrowStatus.Funded,
            targetPrice: targetPrice,
            expiryTimestamp: block.timestamp + duration
        });

        emit EscrowCreated(escrowId, amount, targetPrice);
    }

    /// @notice Release escrowed funds to the beneficiary when the price target is met.
    /// @dev    Anyone can call this — it's permissionless once the condition is satisfied.
    function release(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.status != EscrowStatus.Funded) revert EscrowNotFunded(escrowId);
        if (block.timestamp > escrow.expiryTimestamp) revert EscrowExpiredUseReclaim(escrowId);

        CachedPrice memory cp = cachedPrice;
        if (cp.timestamp == 0) revert NoPriceData();

        uint256 age = block.timestamp - cp.timestamp;
        if (age > priceMaxAge) revert PriceStale(age, priceMaxAge);
        if (cp.price < escrow.targetPrice) revert PriceConditionNotMet(cp.price, escrow.targetPrice);

        escrow.status = EscrowStatus.Released;
        escrow.token.safeTransfer(escrow.beneficiary, escrow.amount);

        emit EscrowReleased(escrowId, cp.price);
    }

    /// @notice Reclaim funds after the escrow has expired. Only the depositor can call.
    function reclaim(uint256 escrowId) external nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (msg.sender != escrow.depositor) revert OnlyDepositor();
        if (escrow.status != EscrowStatus.Funded) revert EscrowNotFunded(escrowId);
        if (block.timestamp <= escrow.expiryTimestamp) revert EscrowNotExpired(escrowId);

        escrow.status = EscrowStatus.Expired;
        escrow.token.safeTransfer(escrow.depositor, escrow.amount);

        emit EscrowExpired(escrowId);
    }

    /// @notice Admin cancels an escrow and returns funds to the depositor.
    function cancel(uint256 escrowId) external onlyOwner nonReentrant {
        Escrow storage escrow = escrows[escrowId];

        if (escrow.status != EscrowStatus.Funded) revert EscrowNotFunded(escrowId);

        escrow.status = EscrowStatus.Cancelled;
        escrow.token.safeTransfer(escrow.depositor, escrow.amount);

        emit EscrowCancelled(escrowId);
    }

    // ════════════════════════════════════════
    // ORACLE CACHE
    // ════════════════════════════════════════

    /// @notice Push a new price into the cache. Admin only.
    /// @param  price      The price value (e.g. 1_500_000_000 for $1.50 with 9 decimals).
    /// @param  timestamp  The timestamp of the price observation.
    function pushPrice(int256 price, uint256 timestamp) external onlyOwner {
        if (price <= 0) revert PriceNotPositive();
        if (cachedPrice.timestamp != 0 && timestamp < cachedPrice.timestamp) {
            revert TimestampOlderThanCached(timestamp, cachedPrice.timestamp);
        }
        if (timestamp > block.timestamp + 60) {
            revert TimestampTooFarInFuture(timestamp, block.timestamp + 60);
        }

        cachedPrice = CachedPrice({price: price, timestamp: timestamp});

        emit PricePushed(price, timestamp);
    }

    // ════════════════════════════════════════
    // ADMIN
    // ════════════════════════════════════════

    /// @notice Update the maximum allowed age (in seconds) of cached price data.
    function setPriceMaxAge(uint256 maxAge) external onlyOwner {
        if (maxAge == 0) revert DurationZero();
        priceMaxAge = maxAge;
        emit PriceMaxAgeUpdated(maxAge);
    }

    // ════════════════════════════════════════
    // VIEW
    // ════════════════════════════════════════

    /// @notice Get full escrow details.
    function getEscrowInfo(uint256 escrowId) external view returns (Escrow memory) {
        return escrows[escrowId];
    }

    /// @notice Get the cached price.
    function getPrice() external view returns (CachedPrice memory) {
        if (cachedPrice.timestamp == 0) revert NoPriceData();
        return cachedPrice;
    }
}
