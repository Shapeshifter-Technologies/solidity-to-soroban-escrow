// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PriceEscrow} from "../src/Escrow.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

contract PriceEscrowTest is Test {
    PriceEscrow public escrow;
    ERC20Mock public token;

    address admin = makeAddr("admin");
    address depositor = makeAddr("depositor");
    address beneficiary = makeAddr("beneficiary");
    address stranger = makeAddr("stranger");

    uint256 constant INITIAL_BALANCE = 1_000_000e18;

    function setUp() public {
        escrow = new PriceEscrow(admin);
        token = new ERC20Mock();

        token.mint(depositor, INITIAL_BALANCE);

        vm.prank(depositor);
        token.approve(address(escrow), type(uint256).max);

        vm.warp(1000);
        vm.prank(admin);
        escrow.pushPrice(2000, 1000);
    }

    // ════════════════════════════════════════
    // DEPLOYMENT
    // ════════════════════════════════════════

    function test_OwnerIsAdmin() public view {
        assertEq(escrow.owner(), admin);
    }

    function test_DefaultPriceMaxAge() public view {
        assertEq(escrow.priceMaxAge(), 300);
    }

    // ════════════════════════════════════════
    // CREATE ESCROW
    // ════════════════════════════════════════

    function test_CreateEscrow() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 100_000e18, 2000, 3600
        );

        assertEq(id, 0);

        PriceEscrow.Escrow memory info = escrow.getEscrowInfo(id);
        assertEq(info.depositor, depositor);
        assertEq(info.beneficiary, beneficiary);
        assertEq(info.amount, 100_000e18);
        assertEq(info.targetPrice, 2000);
        assertEq(uint8(info.status), uint8(PriceEscrow.EscrowStatus.Funded));
        assertEq(token.balanceOf(depositor), INITIAL_BALANCE - 100_000e18);
        assertEq(token.balanceOf(address(escrow)), 100_000e18);
    }

    function test_CreateMultipleEscrows() public {
        vm.startPrank(depositor);
        uint256 id0 = escrow.createEscrow(beneficiary, token, 1000, 2000, 3600);
        uint256 id1 = escrow.createEscrow(beneficiary, token, 2000, 3000, 7200);
        vm.stopPrank();

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(escrow.escrowCount(), 2);
    }

    function test_CreateEscrow_RevertZeroAmount() public {
        vm.prank(depositor);
        vm.expectRevert(PriceEscrow.AmountZero.selector);
        escrow.createEscrow(beneficiary, token, 0, 2000, 3600);
    }

    function test_CreateEscrow_RevertZeroTargetPrice() public {
        vm.prank(depositor);
        vm.expectRevert(PriceEscrow.TargetPriceNotPositive.selector);
        escrow.createEscrow(beneficiary, token, 1000, 0, 3600);
    }

    function test_CreateEscrow_RevertNegativeTargetPrice() public {
        vm.prank(depositor);
        vm.expectRevert(PriceEscrow.TargetPriceNotPositive.selector);
        escrow.createEscrow(beneficiary, token, 1000, -1, 3600);
    }

    function test_CreateEscrow_RevertZeroDuration() public {
        vm.prank(depositor);
        vm.expectRevert(PriceEscrow.DurationZero.selector);
        escrow.createEscrow(beneficiary, token, 1000, 2000, 0);
    }

    function test_CreateEscrow_EmitsEvent() public {
        vm.prank(depositor);
        vm.expectEmit(true, false, false, true);
        emit PriceEscrow.EscrowCreated(0, 50_000e18, 2000);
        escrow.createEscrow(beneficiary, token, 50_000e18, 2000, 3600);
    }

    // ════════════════════════════════════════
    // RELEASE
    // ════════════════════════════════════════

    function test_Release_WhenPriceMet() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        assertEq(token.balanceOf(beneficiary), 0);

        escrow.release(id);

        PriceEscrow.Escrow memory info = escrow.getEscrowInfo(id);
        assertEq(uint8(info.status), uint8(PriceEscrow.EscrowStatus.Released));
        assertEq(token.balanceOf(beneficiary), 50_000e18);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_Release_AnyoneCanCall() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        vm.prank(stranger);
        escrow.release(id);

        PriceEscrow.Escrow memory info = escrow.getEscrowInfo(id);
        assertEq(uint8(info.status), uint8(PriceEscrow.EscrowStatus.Released));
        assertEq(token.balanceOf(beneficiary), 50_000e18);
    }

    function test_Release_EmitsEvent() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        vm.expectEmit(true, false, false, true);
        emit PriceEscrow.EscrowReleased(0, 2000);
        escrow.release(id);
    }

    function test_Release_RevertPriceBelowTarget() public {
        vm.warp(2000);
        vm.prank(admin);
        escrow.pushPrice(500, 2000);

        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        vm.expectRevert(
            abi.encodeWithSelector(PriceEscrow.PriceConditionNotMet.selector, 500, 2000)
        );
        escrow.release(id);
    }

    function test_Release_RevertAfterExpiry() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        vm.warp(block.timestamp + 3601);

        vm.expectRevert(
            abi.encodeWithSelector(PriceEscrow.EscrowExpiredUseReclaim.selector, id)
        );
        escrow.release(id);
    }

    function test_Release_RevertStalePrice() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        vm.warp(1000 + 301);

        vm.expectRevert(
            abi.encodeWithSelector(PriceEscrow.PriceStale.selector, 301, 300)
        );
        escrow.release(id);
    }

    function test_Release_RevertNoPriceData() public {
        PriceEscrow freshEscrow = new PriceEscrow(admin);

        token.mint(depositor, 100_000e18);
        vm.prank(depositor);
        token.approve(address(freshEscrow), type(uint256).max);

        vm.prank(depositor);
        uint256 id = freshEscrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        vm.expectRevert(PriceEscrow.NoPriceData.selector);
        freshEscrow.release(id);
    }

    function test_Release_RevertAlreadyReleased() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 50_000e18, 2000, 3600
        );

        escrow.release(id);

        vm.expectRevert(
            abi.encodeWithSelector(PriceEscrow.EscrowNotFunded.selector, id)
        );
        escrow.release(id);
    }

    // ════════════════════════════════════════
    // RECLAIM
    // ════════════════════════════════════════

    function test_Reclaim_AfterExpiry() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 30_000e18, 10_000, 3600
        );

        uint256 balanceBefore = token.balanceOf(depositor);

        vm.warp(block.timestamp + 3601);

        vm.prank(depositor);
        escrow.reclaim(id);

        PriceEscrow.Escrow memory info = escrow.getEscrowInfo(id);
        assertEq(uint8(info.status), uint8(PriceEscrow.EscrowStatus.Expired));
        assertEq(token.balanceOf(depositor), balanceBefore + 30_000e18);
    }

    function test_Reclaim_EmitsEvent() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 30_000e18, 10_000, 3600
        );

        vm.warp(block.timestamp + 3601);

        vm.prank(depositor);
        vm.expectEmit(true, false, false, false);
        emit PriceEscrow.EscrowExpired(id);
        escrow.reclaim(id);
    }

    function test_Reclaim_RevertBeforeExpiry() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 30_000e18, 10_000, 3600
        );

        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(PriceEscrow.EscrowNotExpired.selector, id)
        );
        escrow.reclaim(id);
    }

    function test_Reclaim_RevertNotDepositor() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 30_000e18, 10_000, 3600
        );

        vm.warp(block.timestamp + 3601);

        vm.prank(stranger);
        vm.expectRevert(PriceEscrow.OnlyDepositor.selector);
        escrow.reclaim(id);
    }

    // ════════════════════════════════════════
    // CANCEL (ADMIN)
    // ════════════════════════════════════════

    function test_Cancel_ByAdmin() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 25_000e18, 2000, 3600
        );

        uint256 balanceBefore = token.balanceOf(depositor);

        vm.prank(admin);
        escrow.cancel(id);

        PriceEscrow.Escrow memory info = escrow.getEscrowInfo(id);
        assertEq(uint8(info.status), uint8(PriceEscrow.EscrowStatus.Cancelled));
        assertEq(token.balanceOf(depositor), balanceBefore + 25_000e18);
    }

    function test_Cancel_EmitsEvent() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 25_000e18, 2000, 3600
        );

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit PriceEscrow.EscrowCancelled(id);
        escrow.cancel(id);
    }

    function test_Cancel_RevertNotAdmin() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 25_000e18, 2000, 3600
        );

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                stranger
            )
        );
        escrow.cancel(id);
    }

    function test_Cancel_RevertAlreadyCancelled() public {
        vm.prank(depositor);
        uint256 id = escrow.createEscrow(
            beneficiary, token, 25_000e18, 2000, 3600
        );

        vm.prank(admin);
        escrow.cancel(id);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(PriceEscrow.EscrowNotFunded.selector, id)
        );
        escrow.cancel(id);
    }

    // ════════════════════════════════════════
    // PUSH PRICE
    // ════════════════════════════════════════

    function test_PushPrice() public {
        vm.warp(2000);
        vm.prank(admin);
        escrow.pushPrice(3000, 2000);

        PriceEscrow.CachedPrice memory cp = escrow.getPrice();
        assertEq(cp.price, 3000);
        assertEq(cp.timestamp, 2000);
    }

    function test_PushPrice_EmitsEvent() public {
        vm.warp(2000);
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit PriceEscrow.PricePushed(3000, 2000);
        escrow.pushPrice(3000, 2000);
    }

    function test_PushPrice_RevertNotAdmin() public {
        vm.warp(2000);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                stranger
            )
        );
        escrow.pushPrice(3000, 2000);
    }

    function test_PushPrice_RevertZeroPrice() public {
        vm.warp(2000);
        vm.prank(admin);
        vm.expectRevert(PriceEscrow.PriceNotPositive.selector);
        escrow.pushPrice(0, 2000);
    }

    function test_PushPrice_RevertNegativePrice() public {
        vm.warp(2000);
        vm.prank(admin);
        vm.expectRevert(PriceEscrow.PriceNotPositive.selector);
        escrow.pushPrice(-1, 2000);
    }

    function test_PushPrice_RevertOlderTimestamp() public {
        vm.warp(2000);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceEscrow.TimestampOlderThanCached.selector, 500, 1000
            )
        );
        escrow.pushPrice(3000, 500);
    }

    function test_PushPrice_RevertTimestampTooFarInFuture() public {
        vm.warp(2000);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PriceEscrow.TimestampTooFarInFuture.selector, 2061, 2060
            )
        );
        escrow.pushPrice(3000, 2061);
    }

    // ════════════════════════════════════════
    // SET PRICE MAX AGE
    // ════════════════════════════════════════

    function test_SetPriceMaxAge() public {
        vm.prank(admin);
        escrow.setPriceMaxAge(600);

        assertEq(escrow.priceMaxAge(), 600);
    }

    function test_SetPriceMaxAge_RevertZero() public {
        vm.prank(admin);
        vm.expectRevert(PriceEscrow.DurationZero.selector);
        escrow.setPriceMaxAge(0);
    }

    function test_SetPriceMaxAge_RevertNotAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                stranger
            )
        );
        escrow.setPriceMaxAge(600);
    }

    // ════════════════════════════════════════
    // VIEW
    // ════════════════════════════════════════

    function test_GetPrice_RevertNoPriceData() public {
        PriceEscrow freshEscrow = new PriceEscrow(admin);

        vm.expectRevert(PriceEscrow.NoPriceData.selector);
        freshEscrow.getPrice();
    }

    // ════════════════════════════════════════
    // ADMIN TRANSFER (Ownable2Step)
    // ════════════════════════════════════════

    function test_TransferOwnership_TwoStep() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        escrow.transferOwnership(newAdmin);

        assertEq(escrow.owner(), admin);

        vm.prank(newAdmin);
        escrow.acceptOwnership();

        assertEq(escrow.owner(), newAdmin);
    }
}
