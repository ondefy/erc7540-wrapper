// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {SemiAsyncRedeemVault} from "../src/SemiAsyncRedeemVault.sol";
import {ISemiAsyncRedeemVault} from "../src/ISemiAsyncRedeemVault.sol";
import {IERC7540Redeem, IERC7540Operator} from "forge-std/interfaces/IERC7540.sol";

contract ERC7540ComplianceTest is Test {
    SmartAccountWrapper public vault;
    ERC20Mock public asset;
    address smartAccount = makeAddr("smartAccount");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");

    uint256 constant MAX_AMOUNT = 100_000 * 1e18;

    function setUp() public {
        SmartAccountWrapper impl = new SmartAccountWrapper();
        asset = new ERC20Mock();
        address beacon = DeployHelper.deployBeacon(address(impl), address(this));
        vault = DeployHelper.deploySmartAccountWrapper(
            beacon, address(this), smartAccount, address(asset), "ERC7540Vault", "E7540"
        );
        asset.mint(user, MAX_AMOUNT);
        asset.mint(user2, MAX_AMOUNT);
    }

    function _deposit(address depositor, uint256 amount) internal {
        vm.startPrank(depositor);
        asset.approve(address(vault), amount);
        vault.deposit(amount, depositor);
        vm.stopPrank();
    }

    function _processWithdrawRequest(uint256 amount) internal {
        vm.startPrank(smartAccount);
        asset.transfer(address(vault), amount);
        vault.transmitDeallocatedAssets(asset.balanceOf(smartAccount));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR SYSTEM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setOperator() public {
        address op = makeAddr("erc7540op");

        assertFalse(vault.isOperator(user, op));

        vm.prank(user);
        bool success = vault.setOperator(op, true);

        assertTrue(success);
        assertTrue(vault.isOperator(user, op));
    }

    function test_setOperator_revoke() public {
        address op = makeAddr("erc7540op");

        vm.startPrank(user);
        vault.setOperator(op, true);
        assertTrue(vault.isOperator(user, op));

        vault.setOperator(op, false);
        assertFalse(vault.isOperator(user, op));
        vm.stopPrank();
    }

    function test_setOperator_emitsEvent() public {
        address op = makeAddr("erc7540op");

        vm.expectEmit(true, true, false, true);
        emit IERC7540Operator.OperatorSet(user, op, true);

        vm.prank(user);
        vault.setOperator(op, true);
    }

    function test_isOperator_defaultFalse() public {
        assertFalse(vault.isOperator(user, makeAddr("random")));
    }

    function test_operatorIndependentPerController() public {
        address op = makeAddr("erc7540op");

        vm.prank(user);
        vault.setOperator(op, true);

        assertTrue(vault.isOperator(user, op));
        assertFalse(vault.isOperator(user2, op));
    }

    /*//////////////////////////////////////////////////////////////
                    REQUEST REDEEM (ERC-7540) TESTS
    //////////////////////////////////////////////////////////////*/

    function test_requestRedeem_returnsRequestId() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;
        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        assertNotEq(requestId, 0, "should return non-zero requestId for async request");
    }

    function test_requestRedeem_returnsZeroForImmediateFulfillment() public {
        _deposit(user, MAX_AMOUNT);
        // Add idle assets so the request can be immediately fulfilled
        asset.mint(address(vault), MAX_AMOUNT / 2);

        uint256 maxRedeem = vault.maxRedeem(user);
        uint256 shares = maxRedeem / 4;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        assertEq(requestId, 0, "should return 0 for fully-immediate request");
    }

    function test_requestRedeem_emitsRedeemRequestEvent() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;
        // We expect the RedeemRequest event but we don't know the requestId ahead of time
        // Just verify the event is emitted
        vm.recordLogs();

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        // Verify RedeemRequest event was emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRedeemRequest = false;
        for (uint256 i = 0; i < entries.length; i++) {
            // RedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets)
            if (entries[i].topics[0] == IERC7540Redeem.RedeemRequest.selector) {
                foundRedeemRequest = true;
                assertEq(address(uint160(uint256(entries[i].topics[1]))), user, "controller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), user, "owner mismatch");
                assertEq(uint256(entries[i].topics[3]), requestId, "requestId mismatch");
            }
        }
        assertTrue(foundRedeemRequest, "RedeemRequest event not emitted");
    }

    function test_requestRedeem_emitsBothEvents() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.recordLogs();

        vm.prank(user);
        vault.requestRedeem(shares, user, user);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundRedeemRequest = false;
        bool foundWithdrawRequested = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == IERC7540Redeem.RedeemRequest.selector) {
                foundRedeemRequest = true;
            }
            if (entries[i].topics[0] == ISemiAsyncRedeemVault.WithdrawRequested.selector) {
                foundWithdrawRequested = true;
            }
        }
        assertTrue(foundRedeemRequest, "RedeemRequest event not emitted");
        assertTrue(foundWithdrawRequested, "WithdrawRequested event not emitted (backward compat)");
    }

    function test_requestRedeem_controllerIsReceiver() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(bytes32(requestId));
        assertEq(request.controller, user, "controller should be user");
        assertEq(request.receiver, user, "receiver should equal controller");
    }

    function test_requestRedeem_controllerDifferentFromOwner() public {
        _deposit(user, MAX_AMOUNT);
        address controller = makeAddr("controller");

        uint256 shares = vault.balanceOf(user) / 2;

        // User approves themselves (caller == owner, no approval needed)
        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, controller, user);

        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(bytes32(requestId));
        assertEq(request.controller, controller, "controller should be set correctly");
        assertEq(request.receiver, controller, "receiver should equal controller in ERC-7540 flow");
        assertEq(request.owner, user, "owner should be user");
    }

    function test_requestRedeem_withAllowance() public {
        _deposit(user, MAX_AMOUNT);
        address spender = makeAddr("spender");
        uint256 shares = vault.balanceOf(user) / 4;

        vm.prank(user);
        vault.approve(spender, shares);

        vm.prank(spender);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        assertNotEq(requestId, 0);
        assertEq(vault.allowance(user, spender), 0, "allowance should be spent");
    }

    /*//////////////////////////////////////////////////////////////
                    PENDING / CLAIMABLE STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_pendingRedeemRequest_beforeFulfillment() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(bytes32(requestId));
        uint256 pending = vault.pendingRedeemRequest(requestId, user);
        assertEq(pending, request.requestedShares, "pending shares should match requested shares");
        assertGt(pending, 0, "pending should be non-zero");
    }

    function test_claimableRedeemRequest_beforeFulfillment_returnsZero() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        uint256 claimable = vault.claimableRedeemRequest(requestId, user);
        assertEq(claimable, 0, "claimable should be zero before fulfillment");
    }

    function test_pendingRedeemRequest_afterFulfillment_returnsZero() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        // Fulfill the request
        _processWithdrawRequest(vault.pendingWithdrawals());

        uint256 pending = vault.pendingRedeemRequest(requestId, user);
        assertEq(pending, 0, "pending should be zero after fulfillment");
    }

    function test_claimableRedeemRequest_afterFulfillment() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(bytes32(requestId));

        // Fulfill the request
        _processWithdrawRequest(vault.pendingWithdrawals());

        uint256 claimable = vault.claimableRedeemRequest(requestId, user);
        assertEq(claimable, request.requestedShares, "claimable shares should match requested shares");
    }

    function test_pendingRedeemRequest_afterClaim_returnsZero() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        _processWithdrawRequest(vault.pendingWithdrawals());
        vault.claim(bytes32(requestId));

        uint256 pending = vault.pendingRedeemRequest(requestId, user);
        assertEq(pending, 0, "pending should be zero after claim");
    }

    function test_claimableRedeemRequest_afterClaim_returnsZero() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        _processWithdrawRequest(vault.pendingWithdrawals());
        vault.claim(bytes32(requestId));

        uint256 claimable = vault.claimableRedeemRequest(requestId, user);
        assertEq(claimable, 0, "claimable should be zero after claim");
    }

    function test_pendingRedeemRequest_wrongController_returnsZero() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        uint256 pending = vault.pendingRedeemRequest(requestId, user2);
        assertEq(pending, 0, "pending should be zero for wrong controller");
    }

    function test_claimableRedeemRequest_wrongController_returnsZero() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        _processWithdrawRequest(vault.pendingWithdrawals());

        uint256 claimable = vault.claimableRedeemRequest(requestId, user2);
        assertEq(claimable, 0, "claimable should be zero for wrong controller");
    }

    function test_pendingRedeemRequest_nonexistentRequest() public view {
        uint256 pending = vault.pendingRedeemRequest(999, user);
        assertEq(pending, 0);
    }

    function test_claimableRedeemRequest_nonexistentRequest() public view {
        uint256 claimable = vault.claimableRedeemRequest(999, user);
        assertEq(claimable, 0);
    }

    /*//////////////////////////////////////////////////////////////
                    REQUEST ID / WITHDRAW KEY CONVERSION
    //////////////////////////////////////////////////////////////*/

    function test_requestIdAndWithdrawKey_areConvertible() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        bytes32 withdrawKey = bytes32(requestId);
        uint256 convertedBack = uint256(withdrawKey);

        assertEq(convertedBack, requestId, "conversion should be lossless");

        // Both should reference the same request
        assertTrue(vault.isClaimable(withdrawKey) == false, "not claimable yet");

        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertEq(request.requestedAssets, vault.previewRedeem(shares), "assets should match");
    }

    function test_requestWithdraw_backwardCompat_setsControllerAsReceiver() public {
        _deposit(user, MAX_AMOUNT);

        uint256 amount = MAX_AMOUNT / 4;

        vm.prank(user);
        bytes32 withdrawKey = vault.requestWithdraw(amount, user, user);

        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(withdrawKey);
        assertEq(request.controller, user, "controller should be receiver for backward compat");
        assertEq(request.receiver, user, "receiver should match");

        // Should also work with ERC-7540 views
        uint256 requestId = uint256(withdrawKey);
        uint256 pending = vault.pendingRedeemRequest(requestId, user);
        assertGt(pending, 0, "should have pending shares via ERC-7540 view");
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM WITH REQUEST ID
    //////////////////////////////////////////////////////////////*/

    function test_claimWithRequestId() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        _processWithdrawRequest(vault.pendingWithdrawals());

        uint256 userBalanceBefore = asset.balanceOf(user);
        vault.claim(bytes32(requestId));

        assertGt(asset.balanceOf(user), userBalanceBefore, "user should receive assets");
        assertTrue(vault.isClaimed(bytes32(requestId)), "should be marked as claimed");
    }

    /*//////////////////////////////////////////////////////////////
                    FULL LIFECYCLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullLifecycle_requestPendingClaimableClaim() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        // 1. Request redeem
        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);
        assertNotEq(requestId, 0);

        // 2. Verify pending state
        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(bytes32(requestId));
        assertGt(vault.pendingRedeemRequest(requestId, user), 0, "should be pending");
        assertEq(vault.claimableRedeemRequest(requestId, user), 0, "should not be claimable");
        assertFalse(vault.isClaimable(bytes32(requestId)), "legacy isClaimable should be false");

        // 3. Fulfill request
        _processWithdrawRequest(vault.pendingWithdrawals());

        // 4. Verify claimable state
        assertEq(vault.pendingRedeemRequest(requestId, user), 0, "should not be pending anymore");
        assertEq(vault.claimableRedeemRequest(requestId, user), request.requestedShares, "should be claimable");
        assertTrue(vault.isClaimable(bytes32(requestId)), "legacy isClaimable should be true");

        // 5. Claim
        uint256 userBalanceBefore = asset.balanceOf(user);
        vault.claim(bytes32(requestId));

        // 6. Verify claimed state
        assertGt(asset.balanceOf(user), userBalanceBefore, "user should receive assets");
        assertEq(vault.pendingRedeemRequest(requestId, user), 0, "pending should be zero");
        assertEq(vault.claimableRedeemRequest(requestId, user), 0, "claimable should be zero");
        assertTrue(vault.isClaimed(bytes32(requestId)), "should be claimed");
    }

    function test_multipleRequests_differentControllers() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares1 = vault.balanceOf(user) / 4;
        uint256 shares2 = vault.balanceOf(user) / 4;

        address controller1 = makeAddr("ctrl1");
        address controller2 = makeAddr("ctrl2");

        vm.startPrank(user);
        uint256 requestId1 = vault.requestRedeem(shares1, controller1, user);
        uint256 requestId2 = vault.requestRedeem(shares2, controller2, user);
        vm.stopPrank();

        // Each request should only be visible to its controller
        assertGt(vault.pendingRedeemRequest(requestId1, controller1), 0);
        assertEq(vault.pendingRedeemRequest(requestId1, controller2), 0);
        assertGt(vault.pendingRedeemRequest(requestId2, controller2), 0);
        assertEq(vault.pendingRedeemRequest(requestId2, controller1), 0);
    }

    function test_requestRedeem_storesRequestedShares() public {
        _deposit(user, MAX_AMOUNT);

        uint256 shares = vault.balanceOf(user) / 2;

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        SemiAsyncRedeemVault.WithdrawRequest memory request = vault.withdrawRequests(bytes32(requestId));
        assertGt(request.requestedShares, 0, "requestedShares should be stored");
    }

    /*//////////////////////////////////////////////////////////////
                    FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_pendingClaimableTransition(uint256 shares) public {
        _deposit(user, MAX_AMOUNT);

        uint256 userShares = vault.balanceOf(user);
        shares = bound(shares, 1, userShares);

        vm.prank(user);
        uint256 requestId = vault.requestRedeem(shares, user, user);

        if (requestId == 0) {
            // Immediate fulfillment - nothing to check
            return;
        }

        // Pending state
        uint256 pending = vault.pendingRedeemRequest(requestId, user);
        uint256 claimable = vault.claimableRedeemRequest(requestId, user);
        assertGt(pending, 0, "should have pending shares");
        assertEq(claimable, 0, "should not be claimable yet");

        // Fulfill
        _processWithdrawRequest(vault.pendingWithdrawals());

        // Claimable state
        pending = vault.pendingRedeemRequest(requestId, user);
        claimable = vault.claimableRedeemRequest(requestId, user);
        assertEq(pending, 0, "should not be pending after fulfillment");
        assertGt(claimable, 0, "should be claimable after fulfillment");

        // Claim
        vault.claim(bytes32(requestId));

        // Zeroed state
        pending = vault.pendingRedeemRequest(requestId, user);
        claimable = vault.claimableRedeemRequest(requestId, user);
        assertEq(pending, 0, "pending zero after claim");
        assertEq(claimable, 0, "claimable zero after claim");
    }

    function testFuzz_operatorApproval(address op, bool approved) public {
        vm.assume(op != address(0));

        vm.prank(user);
        vault.setOperator(op, approved);

        assertEq(vault.isOperator(user, op), approved);
    }
}
