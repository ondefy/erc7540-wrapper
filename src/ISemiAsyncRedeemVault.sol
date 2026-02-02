// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";

/**
 * @title Semi-Async Redeem Vault Interface
 * @notice Extends ERC4626 with ERC-7540 asynchronous redeem workflow
 * @dev Users can request redemptions that are either fulfilled immediately from idle liquidity
 *      or fulfilled later once assets are deallocated from strategies.
 *      Implements IERC7540Redeem (which includes IERC7540Operator).
 */
interface ISemiAsyncRedeemVault is IERC4626, IERC7540Redeem {
    /*//////////////////////////////////////////////////////////////
                          DEPRECATED EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev DEPRECATED: Use RedeemRequest from IERC7540Redeem instead.
     *      Kept for backward compatibility during transition.
     */
    event WithdrawRequested(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        bytes32 withdrawKey,
        uint256 assets,
        uint256 shares
    );

    /**
     * @dev Emitted when a withdrawal request is claimed
     * @param receiver The address that received the claimed assets
     * @param owner The address that owned the burned shares
     * @param withdrawKey Unique identifier for the claimed withdrawal request
     * @param assets The amount of assets claimed and transferred
     */
    event Claimed(address indexed receiver, address indexed owner, bytes32 indexed withdrawKey, uint256 assets);

    /*//////////////////////////////////////////////////////////////
                         DEPRECATED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice DEPRECATED: Requests to withdraw a specific amount of underlying assets
     * @dev Hybrid workflow:
     * - Up to the available idle assets may be sent immediately to the receiver
     * - Any shortfall becomes an asynchronous withdrawal request
     * - The corresponding shares are burned from the owner's balance
     *
     * @param assets The amount of underlying assets to withdraw
     * @param receiver The address that will receive the withdrawn assets
     * @param owner The address that owns the shares being withdrawn
     * @return withdrawKey Unique identifier for the pending shortfall:
     *         - bytes32(0) if the withdrawal was fully satisfied immediately
     *         - Non-zero if a shortfall was requested asynchronously
     */
    function requestWithdraw(uint256 assets, address receiver, address owner) external returns (bytes32);

    /**
     * @notice Checks whether a withdrawal request is ready to be claimed
     * @param withdrawKey The unique identifier of the withdrawal request
     * @return True if the request has been fulfilled and can be claimed
     */
    function isClaimable(bytes32 withdrawKey) external view returns (bool);

    /**
     * @notice Checks whether a withdrawal request has been claimed
     * @param withdrawKey The unique identifier of the withdrawal request
     * @return True if the request has been claimed
     */
    function isClaimed(bytes32 withdrawKey) external view returns (bool);

    /**
     * @notice Claims the assets from a fulfilled withdrawal request
     * @param withdrawKey The unique identifier of the withdrawal request to claim
     * @return The amount of assets transferred to the receiver
     */
    function claim(bytes32 withdrawKey) external returns (uint256);

    /*//////////////////////////////////////////////////////////////
                           VAULT-SPECIFIC VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the maximum amount of underlying assets that can be requested for withdrawal
     * @param owner The address to check the requestable withdrawal limit for
     * @return The maximum assets that can be requested given the owner's balance and current conditions
     */
    function maxRequestWithdraw(address owner) external view returns (uint256);

    /**
     * @notice Returns the maximum amount of vault shares that can be requested for redemption
     * @param owner The address to check the requestable redemption limit for
     * @return The maximum shares that can be requested given the owner's balance and current conditions
     */
    function maxRequestRedeem(address owner) external view returns (uint256);

    /**
     * @notice Returns the total amount of assets currently allocated to strategies
     * @dev These assets are deployed and are not immediately withdrawable until deallocated.
     *      Part of the vault's total asset value but not available for immediate withdrawal.
     *      See ASSET STATE OVERVIEW for complete context.
     * @return The total assets deployed in strategies
     */
    function allocatedAssets() external view returns (uint256);

    /**
     * @notice Returns the amount of assets that can be withdrawn immediately
     * @dev MUST be mutually exclusive with `pendingWithdrawals()` being non-zero:
     *      - If `idleAssets() > 0`, then `pendingWithdrawals()` MUST return 0
     *      - If `pendingWithdrawals() > 0`, then `idleAssets()` MUST return 0
     *
     *      Idle assets include:
     *      - On-hand balance in the vault contract
     *      - Assets claimable from strategies (claimableFromStrategies())
     *      - Minus any reservations for pending withdrawal requests
     *
     *      See ASSET STATE OVERVIEW for complete context.
     * @return The total idle assets available for immediate withdrawal
     */
    function idleAssets() external view returns (uint256);

    /**
     * @notice Returns the total amount of assets requested for withdrawal but not yet fulfilled
     * @dev MUST be mutually exclusive with `idleAssets()` being non-zero:
     *      - If `pendingWithdrawals() > 0`, then `idleAssets()` MUST return 0
     *      - If `idleAssets() > 0`, then `pendingWithdrawals()` MUST return 0
     *
     *      This represents the vault's outstanding obligations to users.
     *      Assets become available for withdrawal as:
     *      - Strategies deallocate assets (pendingDeallocationAssets → claimableFromStrategies)
     *      - Claimable assets are claimed (claimableFromStrategies → idleAssets)
     *
     *      See ASSET STATE OVERVIEW for complete context.
     * @return The total assets across all pending (unfulfilled) withdrawal requests
     */
    function pendingWithdrawals() external view returns (uint256);
}
