// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {DeployHelper} from "../script/utils/DeployHelper.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {SemiAsyncRedeemVault} from "../src/SemiAsyncRedeemVault.sol";

/// @notice Mock ERC-1271 contract that simulates a Safe multisig
contract MockERC1271Wallet is IERC1271 {
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    mapping(address => bool) public owners;
    uint256 public threshold;

    constructor(address[] memory _owners, uint256 _threshold) {
        require(_threshold <= _owners.length, "threshold too high");
        for (uint256 i = 0; i < _owners.length; i++) {
            owners[_owners[i]] = true;
        }
        threshold = _threshold;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        // Each signature is 65 bytes (r: 32, s: 32, v: 1)
        uint256 sigCount = signature.length / 65;
        if (sigCount < threshold) {
            return ERC1271_INVALID;
        }

        uint256 validSigs = 0;
        for (uint256 i = 0; i < sigCount; i++) {
            bytes memory sig = signature[i * 65:(i + 1) * 65];
            address recovered = ECDSA.recover(hash, sig);
            if (owners[recovered]) {
                validSigs++;
            }
        }

        if (validSigs >= threshold) {
            return ERC1271_MAGIC;
        }
        return ERC1271_INVALID;
    }
}

contract SmartAccountWrapperTest is Test {
    SmartAccountWrapper public smartAccountWrapper;
    ERC20Mock public asset;
    address smartAccount = makeAddr("smartAccount");
    address user = makeAddr("user");

    uint256 MAX_AMOUNT = 100000 * 1e18;

    function setUp() public {
        smartAccountWrapper = new SmartAccountWrapper();
        asset = new ERC20Mock();
        address beacon = DeployHelper.deployBeacon(address(smartAccountWrapper), address(this));
        smartAccountWrapper = DeployHelper.deploySmartAccountWrapper(
            beacon, address(this), smartAccount, address(asset), "SmartAccountWrapper", "SAW"
        );
        asset.mint(user, MAX_AMOUNT);
    }

    function test_Deploy() public view {
        assertEq(smartAccountWrapper.smartAccount(), smartAccount, "smartAccount is not the expected smartAccount");
        assertEq(smartAccountWrapper.asset(), address(asset), "asset is not the expected asset");
        assertEq(smartAccountWrapper.name(), "SmartAccountWrapper", "name is not the expected name");
        assertEq(smartAccountWrapper.symbol(), "SAW", "symbol is not the expected symbol");
    }

    function _assertAssetStates(uint256 idle, uint256 pending, uint256 allocated, uint256 total) internal view {
        assertEq(smartAccountWrapper.idleAssets(), idle, "idleAssets is not the expected value");
        assertEq(smartAccountWrapper.pendingWithdrawals(), pending, "pendingWithdrawals is not the expected value");
        assertEq(smartAccountWrapper.allocatedAssets(), allocated, "allocatedAssets is not the expected value");
        assertEq(smartAccountWrapper.totalAssets(), total, "totalAssets is not the expected value");
    }

    function test_Deposit(uint256 amount) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        vm.startPrank(user);
        asset.approve(address(smartAccountWrapper), amount);
        smartAccountWrapper.deposit(amount, user);
        vm.stopPrank();
        _assertAssetStates(0, 0, amount, amount);
        assertEq(asset.balanceOf(smartAccount), amount);
        assertEq(asset.balanceOf(address(smartAccountWrapper)), 0);
    }

    modifier afterDeposit(uint256 amount) {
        test_Deposit(amount);
        _;
    }

    function _processWithdrawRequest(uint256 amount) public {
        vm.startPrank(smartAccount);
        // Transfer tokens from smartAccount to wrapper (simulating deallocation)
        asset.transfer(address(smartAccountWrapper), amount);
        // Update accounting
        smartAccountWrapper.transmitDeallocatedAssets(asset.balanceOf(smartAccount));
        vm.stopPrank();
    }

    function test_ProcessWithdrawRequest(uint256 amount) public afterDeposit(MAX_AMOUNT) {
        amount = bound(amount, 1, MAX_AMOUNT);
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(amount, user, user));
        vm.stopPrank();
        _processWithdrawRequest(smartAccountWrapper.pendingWithdrawals());
        _assertAssetStates(0, 0, MAX_AMOUNT - amount, MAX_AMOUNT - amount);
        assertEq(smartAccountWrapper.isClaimable(withdrawKey), true, "claimable");
        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        smartAccountWrapper.claim(withdrawKey);
        assertEq(asset.balanceOf(user), userBalanceBefore + amount, "user balance is not the expected value");
    }

    function test_ProcessWithdrawRequest_Overflow(uint256 amount) public afterDeposit(MAX_AMOUNT) {
        uint256 overflowAmount = 1;
        amount = bound(amount, 1, MAX_AMOUNT - overflowAmount);
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(amount, user, user));
        vm.stopPrank();
        _processWithdrawRequest(smartAccountWrapper.pendingWithdrawals() + 1);
        _assertAssetStates(1, 0, MAX_AMOUNT - amount - overflowAmount, MAX_AMOUNT - amount);
        assertEq(smartAccountWrapper.isClaimable(withdrawKey), true, "claimable");
        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        smartAccountWrapper.claim(withdrawKey);
        assertEq(asset.balanceOf(user), userBalanceBefore + amount, "user balance is not the expected value");
    }

    function test_AllocateAssets(uint256 amount) public afterDeposit(MAX_AMOUNT) {
        amount = bound(amount, 1, MAX_AMOUNT);
        asset.mint(address(smartAccountWrapper), amount);
        assertEq(smartAccountWrapper.idleAssets(), amount);
        smartAccountWrapper.allocateAssets(amount);
        _assertAssetStates(0, 0, MAX_AMOUNT + amount, MAX_AMOUNT + amount);
    }

    function testRevert_AllocateAssets_NotEnoughIdleAssets(uint256 amount) public afterDeposit(MAX_AMOUNT) {
        amount = bound(amount, 1, MAX_AMOUNT);
        uint256 idle = amount - 1;
        asset.mint(address(smartAccountWrapper), idle);
        assertEq(smartAccountWrapper.idleAssets(), idle);
        vm.expectRevert(abi.encodeWithSelector(SmartAccountWrapper.SA__NotEnoughIdleAssets.selector, amount, idle));
        smartAccountWrapper.allocateAssets(amount);
    }

    function test_TransmitAllocatedAssets(uint256 profit) public afterDeposit(MAX_AMOUNT) {
        profit = bound(profit, 1, MAX_AMOUNT);
        asset.mint(address(smartAccount), profit);
        assertEq(smartAccountWrapper.allocatedAssets(), MAX_AMOUNT);
        vm.startPrank(smartAccount);
        smartAccountWrapper.transmitAllocatedAssets(MAX_AMOUNT + profit);
        vm.stopPrank();
        _assertAssetStates(0, 0, MAX_AMOUNT + profit, MAX_AMOUNT + profit);
    }

    function testRevert_TransmitAllocatedAssets_PendingWithdrawals() public afterDeposit(MAX_AMOUNT) {
        vm.startPrank(user);
        smartAccountWrapper.requestRedeem(MAX_AMOUNT / 10, user, user);
        vm.stopPrank();
        vm.startPrank(smartAccount);
        vm.expectRevert(abi.encodeWithSelector(SmartAccountWrapper.SA__PendingWithdrawals.selector));
        smartAccountWrapper.transmitAllocatedAssets(MAX_AMOUNT);
        vm.stopPrank();
    }

    function testRevert_OnlySmartAccount_transmitAllocatedAssets() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(SmartAccountWrapper.SA__NotSmartAccount.selector));
        smartAccountWrapper.transmitAllocatedAssets(1000);
        vm.stopPrank();
    }

    function testRevert_OnlyOwner_AllocateAssets() public afterDeposit(MAX_AMOUNT) {
        asset.mint(address(smartAccountWrapper), 1000);
        vm.startPrank(user);
        vm.expectRevert();
        smartAccountWrapper.allocateAssets(1000);
        vm.stopPrank();
    }

    function testRevert_OnlySmartAccount_transmitDeallocatedAssets() public afterDeposit(MAX_AMOUNT) {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(SmartAccountWrapper.SA__NotSmartAccount.selector));
        smartAccountWrapper.transmitDeallocatedAssets(MAX_AMOUNT - 1000);
        vm.stopPrank();
    }

    function test_PendingDeallocationAssets() public view {
        assertEq(smartAccountWrapper.pendingDeallocationAssets(), 0);
    }

    function test_ClaimableFromStrategies() public view {
        assertEq(smartAccountWrapper.claimableFromStrategies(), 0);
    }

    function test_MaxWithdraw() public afterDeposit(MAX_AMOUNT) {
        uint256 maxWithdraw = smartAccountWrapper.maxWithdraw(user);
        assertEq(maxWithdraw, 0); // No idle assets after deposit
    }

    function test_MaxRedeem() public afterDeposit(MAX_AMOUNT) {
        uint256 maxRedeem = smartAccountWrapper.maxRedeem(user);
        assertEq(maxRedeem, 0); // No idle assets after deposit
    }

    function test_MaxRequestRedeem() public afterDeposit(MAX_AMOUNT) {
        uint256 maxRequestRedeem = smartAccountWrapper.maxRequestRedeem(user);
        uint256 userShares = smartAccountWrapper.balanceOf(user);
        assertEq(maxRequestRedeem, userShares);
    }

    function test_RequestRedeem() public afterDeposit(MAX_AMOUNT) {
        uint256 shares = MAX_AMOUNT / 1e18 / 2;
        vm.startPrank(user);
        uint256 requestId = smartAccountWrapper.requestRedeem(shares, user, user);
        vm.stopPrank();
        assertNotEq(requestId, 0);
        assertEq(smartAccountWrapper.isClaimable(bytes32(requestId)), false);
    }

    function testRevert_RequestRedeem_ExceededMax() public afterDeposit(MAX_AMOUNT) {
        uint256 userShares = smartAccountWrapper.balanceOf(user);
        uint256 excessShares = userShares + 1;
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                SemiAsyncRedeemVault.SA__ExceededMaxRequestRedeem.selector, user, excessShares, userShares
            )
        );
        smartAccountWrapper.requestRedeem(excessShares, user, user);
        vm.stopPrank();
    }

    function testRevert_Claim_NotClaimable() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(SemiAsyncRedeemVault.SA__NotClaimable.selector, withdrawKey));
        smartAccountWrapper.claim(withdrawKey);
    }

    function test_IsClaimed() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        vm.stopPrank();
        assertEq(smartAccountWrapper.isClaimed(withdrawKey), false);
        _processWithdrawRequest(requestAmount);
        assertEq(smartAccountWrapper.isClaimable(withdrawKey), true);
        vm.prank(user);
        smartAccountWrapper.claim(withdrawKey);
        assertEq(smartAccountWrapper.isClaimed(withdrawKey), true);
    }

    function test_WithdrawRequests() public afterDeposit(MAX_AMOUNT) {
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(MAX_AMOUNT / 10, user, user));
        vm.stopPrank();

        SemiAsyncRedeemVault.WithdrawRequest memory request = smartAccountWrapper.withdrawRequests(withdrawKey);
        assertEq(request.requestedAssets, MAX_AMOUNT / 10);
        assertEq(request.owner, user);
        assertEq(request.receiver, user);
        assertEq(request.controller, user);
        assertEq(request.isClaimed, false);
    }

    function test_GetWithdrawKey() public view {
        bytes32 key1 = smartAccountWrapper.getWithdrawKey(user, 0);
        bytes32 key2 = smartAccountWrapper.getWithdrawKey(user, 1);
        assertNotEq(key1, key2);
    }

    function test_CumulativeRequestedWithdrawalAssets() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.startPrank(user);
        smartAccountWrapper.requestRedeem(requestAmount, user, user);
        vm.stopPrank();
        assertEq(smartAccountWrapper.cumulativeRequestedWithdrawalAssets(), requestAmount);
    }

    function test_CumulativeClaimedAssets() public afterDeposit(MAX_AMOUNT) {
        assertEq(smartAccountWrapper.cumulativeClaimedAssets(), 0);
    }

    function test_TotalAssets() public afterDeposit(MAX_AMOUNT) {
        assertEq(smartAccountWrapper.totalAssets(), MAX_AMOUNT);
    }

    function test_IdleAssets() public afterDeposit(MAX_AMOUNT) {
        assertEq(smartAccountWrapper.idleAssets(), 0);
    }

    function test_PendingWithdrawals() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.startPrank(user);
        smartAccountWrapper.requestRedeem(requestAmount, user, user);
        vm.stopPrank();
        assertEq(smartAccountWrapper.pendingWithdrawals(), requestAmount);
    }

    function test_RequestRedeemWithIdleAssets() public afterDeposit(MAX_AMOUNT) {
        // Add some idle assets
        asset.mint(address(smartAccountWrapper), MAX_AMOUNT / 2);
        uint256 shares = MAX_AMOUNT / 4;

        vm.startPrank(user);
        uint256 requestId = smartAccountWrapper.requestRedeem(shares, user, user);
        vm.stopPrank();

        // Async request created; idle assets cover obligations so pendingWithdrawals = 0
        assertNotEq(requestId, 0);
        assertEq(smartAccountWrapper.pendingWithdrawals(), 0);
    }

    function test_transmitDeallocatedAssets() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        vm.stopPrank();

        // Process the withdrawal request
        _processWithdrawRequest(requestAmount);

        assertEq(smartAccountWrapper.isClaimable(withdrawKey), true);
        assertEq(smartAccountWrapper.pendingWithdrawals(), 0);
    }

    function test_forceTransmitDeallocatedAssets() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        vm.stopPrank();

        // Transfer tokens from smartAccount to wrapper (simulating deallocation)
        vm.prank(smartAccount);
        asset.transfer(address(smartAccountWrapper), requestAmount);

        // Owner updates accounting
        smartAccountWrapper.forceTransmitDeallocatedAssets(asset.balanceOf(smartAccount));

        assertEq(smartAccountWrapper.isClaimable(withdrawKey), true);
        assertEq(smartAccountWrapper.pendingWithdrawals(), 0);
    }

    function test_ClaimAfterProcessing() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.startPrank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        vm.stopPrank();

        // Process the withdrawal request
        _processWithdrawRequest(requestAmount);

        uint256 userBalanceBefore = asset.balanceOf(user);
        vm.prank(user);
        smartAccountWrapper.claim(withdrawKey);
        assertEq(asset.balanceOf(user), userBalanceBefore + requestAmount);
        assertEq(smartAccountWrapper.isClaimed(withdrawKey), true);
    }

    /*//////////////////////////////////////////////////////////////
                    CLAIM AFTER LOSS / GAIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimAfterLoss_PaysReducedAmount() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10; // 10,000e18

        // 1. Request redeem — shares burned, async request created
        vm.prank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));

        // 2. Process: smart account sends tokens back
        _processWithdrawRequest(requestAmount);
        assertEq(smartAccountWrapper.isClaimable(withdrawKey), true);

        // 3. Simulate 50% loss on remaining allocated assets
        //    allocatedAssets was MAX_AMOUNT - requestAmount = 90,000e18
        //    Report only half: 45,000e18
        uint256 allocatedAfterProcess = MAX_AMOUNT - requestAmount;
        uint256 lossyAllocated = allocatedAfterProcess / 2;
        smartAccountWrapper.forceTransmitAllocatedAssets(lossyAllocated);

        // Share price dropped: totalAssets = wrapperBalance(10k) + allocated(45k) - outstanding(10k) = 45k
        // totalSupply = 90k shares → price = 0.5
        uint256 expectedShareValue = smartAccountWrapper.convertToAssets(requestAmount);
        assertLt(expectedShareValue, requestAmount, "share value should be less than requestedAssets");

        // 4. Claim — should get min(requestedAssets, convertToAssets(requestedShares))
        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 claimed = smartAccountWrapper.claim(withdrawKey);

        assertEq(claimed, expectedShareValue, "should pay reduced amount based on share value");
        assertEq(asset.balanceOf(user), balBefore + expectedShareValue);
        assertLt(claimed, requestAmount, "claimed should be less than original request");
    }

    function test_ClaimAfterGain_CappedAtRequestedAssets() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;

        vm.prank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        _processWithdrawRequest(requestAmount);

        // Simulate 2x gain on remaining allocated assets
        uint256 allocatedAfterProcess = MAX_AMOUNT - requestAmount;
        smartAccountWrapper.forceTransmitAllocatedAssets(allocatedAfterProcess * 2);

        // Share price doubled, but payout should be capped at requestedAssets
        uint256 shareValue = smartAccountWrapper.convertToAssets(requestAmount);
        assertGt(shareValue, requestAmount, "share value should exceed requestedAssets");

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 claimed = smartAccountWrapper.claim(withdrawKey);

        // Capped at original requestedAssets — protects remaining shareholders
        assertEq(claimed, requestAmount, "should cap at requestedAssets");
        assertEq(asset.balanceOf(user), balBefore + requestAmount);
    }

    function testFuzz_ClaimAfterLoss(uint256 lossPercent) public afterDeposit(MAX_AMOUNT) {
        // lossPercent: 1-99% loss on allocated assets
        lossPercent = bound(lossPercent, 1, 99);
        uint256 requestAmount = MAX_AMOUNT / 10;

        vm.prank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        _processWithdrawRequest(requestAmount);

        // Apply loss
        uint256 allocatedAfterProcess = MAX_AMOUNT - requestAmount;
        uint256 lossyAllocated = allocatedAfterProcess * (100 - lossPercent) / 100;
        smartAccountWrapper.forceTransmitAllocatedAssets(lossyAllocated);

        uint256 shareValue = smartAccountWrapper.convertToAssets(requestAmount);
        uint256 expectedPayout = shareValue < requestAmount ? shareValue : requestAmount;

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 claimed = smartAccountWrapper.claim(withdrawKey);

        assertEq(claimed, expectedPayout, "payout = min(requestedAssets, currentShareValue)");
        assertEq(asset.balanceOf(user), balBefore + expectedPayout);
    }

    function test_MultipleWithdrawRequests() public afterDeposit(MAX_AMOUNT) {
        uint256 request1 = MAX_AMOUNT / 10;
        uint256 request2 = MAX_AMOUNT / 20;

        vm.startPrank(user);
        bytes32 withdrawKey1 = bytes32(smartAccountWrapper.requestRedeem(request1, user, user));
        bytes32 withdrawKey2 = bytes32(smartAccountWrapper.requestRedeem(request2, user, user));
        vm.stopPrank();

        assertEq(smartAccountWrapper.pendingWithdrawals(), request1 + request2);
        assertEq(smartAccountWrapper.cumulativeRequestedWithdrawalAssets(), request1 + request2);

        // Process first request
        _processWithdrawRequest(request1);
        assertEq(smartAccountWrapper.isClaimable(withdrawKey1), true);
        assertEq(smartAccountWrapper.isClaimable(withdrawKey2), false);

        // Process second request
        _processWithdrawRequest(request2);
        assertEq(smartAccountWrapper.isClaimable(withdrawKey2), true);
    }

    function test_AllowanceSpending() public afterDeposit(MAX_AMOUNT) {
        address spender = makeAddr("spender");
        uint256 requestAmount = MAX_AMOUNT / 10;

        vm.startPrank(user);
        smartAccountWrapper.approve(spender, requestAmount);
        // ERC-7540: spender also needs operator approval from the controller (user)
        smartAccountWrapper.setOperator(spender, true);
        vm.stopPrank();

        vm.startPrank(spender);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        vm.stopPrank();

        assertNotEq(withdrawKey, bytes32(0));
        assertEq(smartAccountWrapper.allowance(user, spender), 0);
    }

    function test_upgrade() public {
        address owner = 0xd1DD21D53eC43C8FE378E51029Aa3F380b229c98;
        address beacon = 0x94062886D060E3a80aaB17951c6E087a153e8AE8;
        address wrapper = 0xf3Cfe4f445a6d4C95e02F9A66eDCFABF9Ea5E7cd;
        SmartAccountWrapper _wrapper = SmartAccountWrapper(wrapper);
        vm.createSelectFork("base", 37692185);
        vm.startPrank(owner);
        UpgradeableBeacon(beacon).upgradeTo(address(new SmartAccountWrapper()));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          ERC-1271 TESTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant OWNER_PRIVATE_KEY = 0xA11CE;
    uint256 constant WRONG_PRIVATE_KEY = 0xB0B;
    bytes4 constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 constant ERC1271_INVALID = 0xffffffff;

    function _deployWithEOAOwner(uint256 privateKey) internal returns (SmartAccountWrapper, address) {
        address eoaOwner = vm.addr(privateKey);
        SmartAccountWrapper wrapper = new SmartAccountWrapper();
        address beacon = DeployHelper.deployBeacon(address(wrapper), address(this));
        wrapper = DeployHelper.deploySmartAccountWrapper(
            beacon, eoaOwner, smartAccount, address(asset), "SmartAccountWrapper", "SAW"
        );
        return (wrapper, eoaOwner);
    }

    function test_isValidSignature_EOA_ValidSignature() public {
        (SmartAccountWrapper wrapper, address eoaOwner) = _deployWithEOAOwner(OWNER_PRIVATE_KEY);
        assertEq(wrapper.owner(), eoaOwner);

        bytes32 hash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PRIVATE_KEY, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = wrapper.isValidSignature(hash, signature);
        assertEq(result, ERC1271_MAGIC_VALUE, "should return magic value for valid signature");
    }

    function test_isValidSignature_EOA_WrongSigner() public {
        (SmartAccountWrapper wrapper,) = _deployWithEOAOwner(OWNER_PRIVATE_KEY);

        bytes32 hash = keccak256("test message");
        // Sign with different key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_PRIVATE_KEY, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes4 result = wrapper.isValidSignature(hash, signature);
        assertEq(result, ERC1271_INVALID, "should return invalid for wrong signer");
    }

    function test_isValidSignature_EOA_InvalidSignature() public {
        (SmartAccountWrapper wrapper,) = _deployWithEOAOwner(OWNER_PRIVATE_KEY);

        bytes32 hash = keccak256("test message");
        bytes memory invalidSig = new bytes(65); // All zeros

        bytes4 result = wrapper.isValidSignature(hash, invalidSig);
        assertEq(result, ERC1271_INVALID, "should return invalid for malformed signature");
    }

    function test_isValidSignature_EOA_WrongHash() public {
        (SmartAccountWrapper wrapper,) = _deployWithEOAOwner(OWNER_PRIVATE_KEY);

        bytes32 hash = keccak256("test message");
        bytes32 wrongHash = keccak256("wrong message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PRIVATE_KEY, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Verify against wrong hash
        bytes4 result = wrapper.isValidSignature(wrongHash, signature);
        assertEq(result, ERC1271_INVALID, "should return invalid for wrong hash");
    }

    function test_isValidSignature_EOA_EmptySignature() public {
        (SmartAccountWrapper wrapper,) = _deployWithEOAOwner(OWNER_PRIVATE_KEY);

        bytes32 hash = keccak256("test message");
        bytes memory emptySig = "";

        bytes4 result = wrapper.isValidSignature(hash, emptySig);
        assertEq(result, ERC1271_INVALID, "should return invalid for empty signature");
    }

    // Smart Contract Operator Tests (simulating Safe multisig)
    uint256 constant OWNER1_KEY = 0x1111;
    uint256 constant OWNER2_KEY = 0x2222;
    uint256 constant OWNER3_KEY = 0x3333;
    uint256 constant NON_OWNER_KEY = 0x9999;

    function _deployWithContractOwner(uint256 threshold)
        internal
        returns (SmartAccountWrapper, MockERC1271Wallet)
    {
        address[] memory owners = new address[](3);
        owners[0] = vm.addr(OWNER1_KEY);
        owners[1] = vm.addr(OWNER2_KEY);
        owners[2] = vm.addr(OWNER3_KEY);

        MockERC1271Wallet mockWallet = new MockERC1271Wallet(owners, threshold);

        SmartAccountWrapper wrapper = new SmartAccountWrapper();
        address beacon = DeployHelper.deployBeacon(address(wrapper), address(this));
        wrapper = DeployHelper.deploySmartAccountWrapper(
            beacon, address(mockWallet), smartAccount, address(asset), "SmartAccountWrapper", "SAW"
        );
        return (wrapper, mockWallet);
    }

    function _sign(uint256 privateKey, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);
        return abi.encodePacked(r, s, v);
    }

    function test_isValidSignature_Contract_ValidSignature_2of3() public {
        (SmartAccountWrapper wrapper,) = _deployWithContractOwner(2);

        bytes32 hash = keccak256("test message");

        // Sign with 2 owners
        bytes memory sig1 = _sign(OWNER1_KEY, hash);
        bytes memory sig2 = _sign(OWNER2_KEY, hash);
        bytes memory signatures = abi.encodePacked(sig1, sig2);

        bytes4 result = wrapper.isValidSignature(hash, signatures);
        assertEq(result, ERC1271_MAGIC_VALUE, "should return magic value for valid 2-of-3 signatures");
    }

    function test_isValidSignature_Contract_ValidSignature_3of3() public {
        (SmartAccountWrapper wrapper,) = _deployWithContractOwner(3);

        bytes32 hash = keccak256("test message");

        // Sign with all 3 owners
        bytes memory sig1 = _sign(OWNER1_KEY, hash);
        bytes memory sig2 = _sign(OWNER2_KEY, hash);
        bytes memory sig3 = _sign(OWNER3_KEY, hash);
        bytes memory signatures = abi.encodePacked(sig1, sig2, sig3);

        bytes4 result = wrapper.isValidSignature(hash, signatures);
        assertEq(result, ERC1271_MAGIC_VALUE, "should return magic value for valid 3-of-3 signatures");
    }

    function test_isValidSignature_Contract_InsufficientSignatures() public {
        (SmartAccountWrapper wrapper,) = _deployWithContractOwner(2);

        bytes32 hash = keccak256("test message");

        // Only 1 signature for 2-of-3 threshold
        bytes memory sig1 = _sign(OWNER1_KEY, hash);

        bytes4 result = wrapper.isValidSignature(hash, sig1);
        assertEq(result, ERC1271_INVALID, "should return invalid for insufficient signatures");
    }

    function test_isValidSignature_Contract_NonOwnerSignatures() public {
        (SmartAccountWrapper wrapper,) = _deployWithContractOwner(2);

        bytes32 hash = keccak256("test message");

        // Sign with non-owners
        bytes memory sig1 = _sign(NON_OWNER_KEY, hash);
        bytes memory sig2 = _sign(WRONG_PRIVATE_KEY, hash);
        bytes memory signatures = abi.encodePacked(sig1, sig2);

        bytes4 result = wrapper.isValidSignature(hash, signatures);
        assertEq(result, ERC1271_INVALID, "should return invalid for non-owner signatures");
    }

    function test_isValidSignature_Contract_MixedOwnerNonOwner() public {
        (SmartAccountWrapper wrapper,) = _deployWithContractOwner(2);

        bytes32 hash = keccak256("test message");

        // 1 owner + 1 non-owner (threshold is 2)
        bytes memory sig1 = _sign(OWNER1_KEY, hash);
        bytes memory sig2 = _sign(NON_OWNER_KEY, hash);
        bytes memory signatures = abi.encodePacked(sig1, sig2);

        bytes4 result = wrapper.isValidSignature(hash, signatures);
        assertEq(result, ERC1271_INVALID, "should return invalid when not enough owner signatures");
    }

    /*//////////////////////////////////////////////////////////////
                      2-STEP OWNERSHIP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TwoStepOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: current owner initiates transfer
        smartAccountWrapper.transferOwnership(newOwner);
        // Owner hasn't changed yet
        assertEq(smartAccountWrapper.owner(), address(this));
        assertEq(smartAccountWrapper.pendingOwner(), newOwner);

        // Step 2: new owner accepts
        vm.prank(newOwner);
        smartAccountWrapper.acceptOwnership();
        assertEq(smartAccountWrapper.owner(), newOwner);
        assertEq(smartAccountWrapper.pendingOwner(), address(0));
    }

    function test_PendingOwnerCannotActAsOwner() public {
        address newOwner = makeAddr("newOwner");

        smartAccountWrapper.transferOwnership(newOwner);

        // Pending owner tries to call onlyOwner function before accepting
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, newOwner));
        smartAccountWrapper.forceTransmitAllocatedAssets(0);
    }

    /*//////////////////////////////////////////////////////////////
                          PAUSABLE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PauseUnpause() public {
        assertEq(smartAccountWrapper.paused(), false);
        smartAccountWrapper.pause();
        assertEq(smartAccountWrapper.paused(), true);
        smartAccountWrapper.unpause();
        assertEq(smartAccountWrapper.paused(), false);
    }

    function testRevert_PauseNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        smartAccountWrapper.pause();
    }

    function testRevert_UnpauseNotOwner() public {
        smartAccountWrapper.pause();
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        smartAccountWrapper.unpause();
    }

    function testRevert_DepositWhenPaused() public {
        smartAccountWrapper.pause();
        vm.startPrank(user);
        asset.approve(address(smartAccountWrapper), 1000);
        vm.expectRevert();
        smartAccountWrapper.deposit(1000, user);
        vm.stopPrank();
    }

    function testRevert_MintWhenPaused() public {
        smartAccountWrapper.pause();
        vm.startPrank(user);
        asset.approve(address(smartAccountWrapper), 1000);
        vm.expectRevert();
        smartAccountWrapper.mint(1000, user);
        vm.stopPrank();
    }

    function testRevert_RequestRedeemWhenPaused() public afterDeposit(MAX_AMOUNT) {
        smartAccountWrapper.pause();
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        smartAccountWrapper.requestRedeem(100, user, user);
    }

    function test_MaxDeposit_ReturnsZeroWhenPaused() public {
        smartAccountWrapper.pause();
        assertEq(smartAccountWrapper.maxDeposit(user), 0);
    }

    function test_MaxMint_ReturnsZeroWhenPaused() public {
        smartAccountWrapper.pause();
        assertEq(smartAccountWrapper.maxMint(user), 0);
    }

    function test_MaxRequestRedeem_ReturnsZeroWhenPaused() public afterDeposit(MAX_AMOUNT) {
        smartAccountWrapper.pause();
        assertEq(smartAccountWrapper.maxRequestRedeem(user), 0);
    }

    function test_ClaimStillWorksWhenPaused() public afterDeposit(MAX_AMOUNT) {
        uint256 requestAmount = MAX_AMOUNT / 10;
        vm.prank(user);
        bytes32 withdrawKey = bytes32(smartAccountWrapper.requestRedeem(requestAmount, user, user));
        _processWithdrawRequest(requestAmount);

        // Pause after request is claimable
        smartAccountWrapper.pause();

        // Claim should still work — users must be able to exit
        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        smartAccountWrapper.claim(withdrawKey);
        assertEq(asset.balanceOf(user), balBefore + requestAmount);
    }

    function test_DepositWorksAfterUnpause() public {
        smartAccountWrapper.pause();
        smartAccountWrapper.unpause();

        vm.startPrank(user);
        asset.approve(address(smartAccountWrapper), 1000);
        smartAccountWrapper.deposit(1000, user);
        vm.stopPrank();
        assertEq(smartAccountWrapper.totalAssets(), 1000);
    }

    function test_isValidSignature_Contract_WrongHash() public {
        (SmartAccountWrapper wrapper,) = _deployWithContractOwner(2);

        bytes32 hash = keccak256("test message");
        bytes32 wrongHash = keccak256("wrong message");

        bytes memory sig1 = _sign(OWNER1_KEY, hash);
        bytes memory sig2 = _sign(OWNER2_KEY, hash);
        bytes memory signatures = abi.encodePacked(sig1, sig2);

        // Verify against wrong hash
        bytes4 result = wrapper.isValidSignature(wrongHash, signatures);
        assertEq(result, ERC1271_INVALID, "should return invalid for wrong hash");
    }
}
