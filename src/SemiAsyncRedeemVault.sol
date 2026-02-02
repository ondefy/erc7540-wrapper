// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {ISemiAsyncRedeemVault} from "./ISemiAsyncRedeemVault.sol";
import {IERC7540Redeem, IERC7540Operator} from "forge-std/interfaces/IERC7540.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/*
 * ASSET STATE OVERVIEW:
 *
 * The vault manages assets across several distinct states:
 *
 * 1. IDLE ASSETS (idleAssets())
 *    - Assets immediately available for withdrawal
 *    - Includes on-hand balance + claimable from strategies
 *    - Mutually exclusive with pendingWithdrawals() > 0
 *
 * 2. ALLOCATED ASSETS (allocatedAssets())
 *    - Assets currently deployed in external strategies
 *    - Earning yield but not immediately withdrawable
 *    - Must be deallocated before becoming available
 *
 * 3. PENDING DEALLOCATION ASSETS (pendingDeallocationAssets())
 *    - Assets requested for withdrawal from strategies
 *    - In transit/processing but not yet claimable
 *    - Will become claimable once deallocation completes
 *
 * 4. CLAIMABLE FROM STRATEGIES (claimableFromStrategies())
 *    - Assets ready to be claimed from strategies
 *    - Part of idle assets calculation
 *    - Can be claimed immediately via _claimFromStrategies()
 *
 * 5. PENDING WITHDRAWALS (pendingWithdrawals())
 *    - Total user withdrawal requests not yet fulfilled
 *    - Mutually exclusive with idleAssets() > 0
 *    - Represents outstanding obligations to users
 *
 * RELATIONSHIPS:
 * - idleAssets() + pendingWithdrawals() = total user obligations
 * - allocatedAssets() + pendingDeallocationAssets() = total strategy exposure
 * - idleAssets() and pendingWithdrawals() are mutually exclusive
 */
abstract contract SemiAsyncRedeemVault is Initializable, ERC4626Upgradeable, NoncesUpgradeable, ISemiAsyncRedeemVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct WithdrawRequest {
        uint256 requestedAssets;
        uint256 cumulativeRequestedWithdrawalAssets;
        uint256 requestTimestamp;
        address owner;
        address receiver;
        bool isClaimed;
        // --- New fields appended for ERC-7540 (upgrade-safe) ---
        uint256 requestedShares;
        address controller;
    }

    /*//////////////////////////////////////////////////////////////
                       NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:zyfai.storage.SemiAsyncRedeemVault
    struct SemiAsyncRedeemVaultStorage {
        // user's withdraw related state
        uint256 cumulativeRequestedWithdrawalAssets;
        uint256 cumulativeClaimedAssets;
        mapping(bytes32 withdrawKey => WithdrawRequest) withdrawRequests;
        // ERC-7540 operator system
        mapping(address controller => mapping(address op => bool)) operators;
    }

    // keccak256(abi.encode(uint256(keccak256("zyfai.storage.SemiAsyncRedeemVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SEMI_ASYNC_REDEEM_VAULT_STORAGE_LOCATION =
        0x642da26731cbaa7c1ced9fb3fed6b9b3be5b80a69e65cdafcc9f925523464f00;

    function _getSemiAsyncRedeemVaultStorage() private pure returns (SemiAsyncRedeemVaultStorage storage $) {
        assembly {
            $.slot := SEMI_ASYNC_REDEEM_VAULT_STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SA__ExceededMaxRequestWithdraw(address owner, uint256 assets, uint256 maxAllowed);
    error SA__ExceededMaxRequestRedeem(address owner, uint256 shares, uint256 maxAllowed);
    error SA__NotClaimable(bytes32 withdrawKey);

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HOOKS
    //////////////////////////////////////////////////////////////*/

    function _claimFromStrategies() internal virtual {}

    /*//////////////////////////////////////////////////////////////
        VIRTUAL FUNCTIONS NEED TO BE IMPLEMENTED BY INHERITORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function allocatedAssets() public view virtual returns (uint256);

    function pendingDeallocationAssets() public view virtual returns (uint256);

    function claimableFromStrategies() public view virtual returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        ERC-7540 OPERATOR SYSTEM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC7540Operator
    function setOperator(address op, bool approved) external returns (bool) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        $.operators[_msgSender()][op] = approved;
        emit OperatorSet(_msgSender(), op, approved);
        return true;
    }

    /// @inheritdoc IERC7540Operator
    function isOperator(address controller, address op) public view returns (bool status) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        return $.operators[controller][op];
    }

    /*//////////////////////////////////////////////////////////////
                           PUBLIC/EXTERNAL VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ERC4626Upgradeable
     */
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        (, uint256 assets) = (vaultBalance + allocatedAssets() + pendingDeallocationAssets()
                + claimableFromStrategies())
        .trySub(_outstandingObligations());
        return assets;
    }

    /**
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function idleAssets() public view returns (uint256) {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        (, uint256 assets) = (vaultBalance + claimableFromStrategies()).trySub(_outstandingObligations());
        return assets;
    }

    /**
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function pendingWithdrawals() public view returns (uint256) {
        uint256 outstanding = _outstandingObligations();
        if (outstanding == 0) return 0;

        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 processed = vaultBalance + claimableFromStrategies() + pendingDeallocationAssets();

        if (processed >= outstanding) return 0;

        // Use unchecked math since processed < outstanding is guaranteed by the logic
        unchecked {
            return outstanding - processed;
        }
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Semi-async constraint: limited by immediately withdrawable liquidity. Returns
     *      min(convertToAssets(balanceOf(owner)), idleAssets()).
     */
    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        uint256 immediate = idleAssets();
        return Math.min(ownerAssets, immediate);
    }

    /**
     * @inheritdoc ERC4626Upgradeable
     * @dev Semi-async constraint: limited by shares that map to idle assets. Returns
     *      min(balanceOf(owner), _convertToShares(idleAssets(), Math.Rounding.Floor)).
     */
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 ownerShares = balanceOf(owner);
        uint256 redeemableShares = _convertToShares(idleAssets(), Math.Rounding.Floor);
        return Math.min(ownerShares, redeemableShares);
    }

    /**
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function maxRequestWithdraw(address owner) public view returns (uint256) {
        // User can always request up to their max withdrawable assets; any shortfall becomes pending
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function maxRequestRedeem(address owner) public view returns (uint256) {
        // User can request to redeem up to their shares; any shortfall in assets becomes pending
        return balanceOf(owner);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-7540 PENDING/CLAIMABLE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IERC7540Redeem
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 pendingShares)
    {
        bytes32 withdrawKey = bytes32(requestId);
        WithdrawRequest memory request = _getSemiAsyncRedeemVaultStorage().withdrawRequests[withdrawKey];

        if (request.controller != controller) return 0;
        if (request.isClaimed) return 0;
        if (request.requestedShares == 0) return 0;

        // If claimable, it's not pending
        if (_isClaimableInternal(request)) return 0;

        return request.requestedShares;
    }

    /// @inheritdoc IERC7540Redeem
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 claimableShares)
    {
        bytes32 withdrawKey = bytes32(requestId);
        WithdrawRequest memory request = _getSemiAsyncRedeemVaultStorage().withdrawRequests[withdrawKey];

        if (request.controller != controller) return 0;
        if (request.isClaimed) return 0;
        if (request.requestedShares == 0) return 0;

        if (_isClaimableInternal(request)) {
            return request.requestedShares;
        }

        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626Upgradeable
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        _claimFromStrategies();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev DEPRECATED: Use requestRedeem with ERC-7540 interface instead.
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function requestWithdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        returns (bytes32 withdrawKey)
    {
        // Enforce requestable limit
        uint256 maxRequestAssets = maxRequestWithdraw(owner);
        if (assets > maxRequestAssets) revert SA__ExceededMaxRequestWithdraw(owner, assets, maxRequestAssets);

        uint256 shares = previewWithdraw(assets);

        // For backward compat: receiver serves as both controller and receiver
        return _processRequest(assets, shares, receiver, receiver, owner);
    }

    /**
     * @notice Requests to redeem a specific amount of vault shares (ERC-7540 compliant)
     * @dev Semi-async hybrid workflow:
     * - The specified shares are burned from the owner's balance
     * - Up to the available idle assets may be sent immediately to the controller
     * - Any shortfall becomes an asynchronous withdrawal request
     *
     * @param shares The amount of vault shares to redeem
     * @param controller The controller who manages the request and receives assets
     * @param owner The address that owns the shares being redeemed
     * @return requestId ERC-7540 request identifier:
     *         - 0 if the redemption was fully satisfied immediately
     *         - Non-zero if a shortfall was requested asynchronously
     */
    function requestRedeem(uint256 shares, address controller, address owner)
        public
        virtual
        returns (uint256 requestId)
    {
        // Enforce requestable limit
        uint256 maxRequestShares = maxRequestRedeem(owner);
        if (shares > maxRequestShares) revert SA__ExceededMaxRequestRedeem(owner, shares, maxRequestShares);

        uint256 assets = previewRedeem(shares);

        // Controller is both controller and receiver in ERC-7540 flow
        bytes32 withdrawKey = _processRequest(assets, shares, controller, controller, owner);
        return uint256(withdrawKey);
    }

    function _processRequest(uint256 assets, uint256 shares, address controller, address receiver, address owner)
        internal
        returns (bytes32)
    {
        uint256 maxAssets = maxWithdraw(owner);
        uint256 assetsToWithdraw = Math.min(assets, maxAssets);
        // always assetsToWithdraw <= assets
        uint256 assetsToRequest = assets - assetsToWithdraw;

        uint256 sharesToRedeem = _convertToShares(assetsToWithdraw, Math.Rounding.Ceil);
        uint256 sharesToRequest = shares - sharesToRedeem;

        if (assetsToWithdraw > 0) _withdraw(_msgSender(), receiver, owner, assetsToWithdraw, sharesToRedeem);

        if (assetsToRequest > 0) {
            return _requestWithdraw(_msgSender(), controller, receiver, owner, assetsToRequest, sharesToRequest);
        }
        return bytes32(0);
    }

    /// @dev requestWithdraw/requestRedeem common workflow.
    function _requestWithdraw(
        address caller,
        address controller,
        address receiver,
        address owner,
        uint256 assetsToRequest,
        uint256 sharesToRequest
    ) internal virtual returns (bytes32) {
        if (caller != owner) {
            _spendAllowance(owner, caller, sharesToRequest);
        }
        _burn(owner, sharesToRequest);

        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        uint256 newCumulativeRequestedWithdrawalAssets = cumulativeRequestedWithdrawalAssets() + assetsToRequest;
        $.cumulativeRequestedWithdrawalAssets = newCumulativeRequestedWithdrawalAssets;

        uint256 nonce = _useNonce(owner);
        bytes32 withdrawKey = _computeWithdrawKey(owner, nonce);

        $.withdrawRequests[withdrawKey] = WithdrawRequest({
            requestedAssets: assetsToRequest,
            cumulativeRequestedWithdrawalAssets: newCumulativeRequestedWithdrawalAssets,
            requestTimestamp: block.timestamp,
            owner: owner,
            receiver: receiver,
            isClaimed: false,
            requestedShares: sharesToRequest,
            controller: controller
        });

        // Emit ERC-7540 event
        emit RedeemRequest(controller, owner, uint256(withdrawKey), caller, assetsToRequest);
        // Emit deprecated event for backward compatibility
        emit WithdrawRequested(caller, receiver, owner, withdrawKey, assetsToRequest, sharesToRequest);

        return withdrawKey;
    }

    /**
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function isClaimable(bytes32 withdrawKey) public view returns (bool) {
        WithdrawRequest memory request = _getSemiAsyncRedeemVaultStorage().withdrawRequests[withdrawKey];
        return _isClaimableInternal(request);
    }

    function isClaimed(bytes32 withdrawKey) public view returns (bool) {
        return _getSemiAsyncRedeemVaultStorage().withdrawRequests[withdrawKey].isClaimed;
    }

    /**
     * @inheritdoc ISemiAsyncRedeemVault
     */
    function claim(bytes32 withdrawKey) public returns (uint256) {
        if (!isClaimable(withdrawKey)) revert SA__NotClaimable(withdrawKey);

        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        WithdrawRequest storage request = $.withdrawRequests[withdrawKey];

        // Mark claimed first to prevent reentrancy drain
        request.isClaimed = true;

        uint256 amount = request.requestedAssets;

        // Account claimed amount against fulfilled
        $.cumulativeClaimedAssets += amount;

        _claimFromStrategies();

        // Transfer to receiver
        IERC20(asset()).safeTransfer(request.receiver, amount);

        emit Claimed(request.receiver, request.owner, withdrawKey, amount);
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal claimability check used by both isClaimable() and ERC-7540 views
    function _isClaimableInternal(WithdrawRequest memory request) internal view returns (bool) {
        if (request.isClaimed || request.requestedAssets == 0) return false;
        return cumulativeClaimedAssets() + IERC20(asset()).balanceOf(address(this)) + claimableFromStrategies()
            >= request.cumulativeRequestedWithdrawalAssets;
    }

    // Helper to compute outstanding obligations without storing an extra variable
    function _outstandingObligations() internal view returns (uint256) {
        uint256 requested = cumulativeRequestedWithdrawalAssets();
        uint256 claimed = cumulativeClaimedAssets();
        // assert requested >= claimed
        unchecked {
            return requested - claimed;
        }
    }

    // Helper to compute a unique key for a withdrawal request
    function _computeWithdrawKey(address owner, uint256 nonce) internal view returns (bytes32 result) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, address())
            mstore(add(ptr, 0x20), owner)
            mstore(add(ptr, 0x40), nonce)
            result := keccak256(ptr, 0x60)
            mstore(0x40, add(ptr, 0x60))
        }
    }

    function cumulativeRequestedWithdrawalAssets() public view returns (uint256) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        return $.cumulativeRequestedWithdrawalAssets;
    }

    function cumulativeClaimedAssets() public view returns (uint256) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        return $.cumulativeClaimedAssets;
    }

    function withdrawRequests(bytes32 withdrawKey) public view returns (WithdrawRequest memory) {
        SemiAsyncRedeemVaultStorage storage $ = _getSemiAsyncRedeemVaultStorage();
        return $.withdrawRequests[withdrawKey];
    }

    /// @notice Calculate withdraw request key given a user and their nonce
    function getWithdrawKey(address user, uint256 nonce) public view returns (bytes32) {
        return _computeWithdrawKey(user, nonce);
    }
}
