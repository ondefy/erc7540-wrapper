// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC7540Redeem, IERC7540Operator} from "forge-std/interfaces/IERC7540.sol";

import {SemiAsyncRedeemVault} from "./SemiAsyncRedeemVault.sol";

contract SmartAccountWrapper is
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    SemiAsyncRedeemVault,
    IERC1271
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice ERC-1271 magic value for valid signatures
    bytes4 private constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

    /// @notice Return value for invalid signatures
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error SA__NotSmartAccount();
    error SA__SmartAccountNotSet();
    error SA__NotEnoughIdleAssets(uint256 assets, uint256 idleAssets);
    error SA__PendingWithdrawals();
    error SA__DeallocatedAssetsExceedAllocated(uint256 remaining, uint256 allocated);
    error SA__ZeroAddress();
    error SA__NotEnoughVaultBalance(uint256 assets, uint256 vaultBalance);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event AllocatedAssetsTransmitted(uint256 newAllocatedAssets);
    event DeallocatedAssetsTransmitted(uint256 remainingAllocatedAssets);
    event AssetsAllocated(uint256 assets);
    event SmartAccountSet(address smartAccount);

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE LAYOUT
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:zyfai.storage.SmartAccountWrapper
    struct SmartAccountWrapperStorage {
        address smartAccount;
        uint256 allocatedAssets;
    }

    // keccak256(abi.encode(uint256(keccak256("zyfai.storage.SmartAccountWrapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SMART_ACCOUNT_WRAPPER_STORAGE_LOCATION =
        0x0b4df025537faa360009ab68a91bc7272fab48607bc6e74d5be7ac40332a8400;

    function _getSmartAccountWrapperStorage() private pure returns (SmartAccountWrapperStorage storage $) {
        assembly {
            $.slot := SMART_ACCOUNT_WRAPPER_STORAGE_LOCATION
        }
    }

    modifier onlySmartAccount() {
        _checkSmartAccount();
        _;
    }

    function _checkSmartAccount() internal view {
        address _smartAccount = _getSmartAccountWrapperStorage().smartAccount;
        if (_smartAccount == address(0)) revert SA__SmartAccountNotSet();
        if (_smartAccount != _msgSender()) revert SA__NotSmartAccount();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/
    function initialize(
        address owner_,
        address smartAccount_,
        address underlyingToken_,
        string memory name_,
        string memory symbol_
    ) public initializer {
        if (underlyingToken_ == address(0)) revert SA__ZeroAddress();
        __Ownable_init(owner_);
        __Pausable_init();
        __ERC20_init_unchained(name_, symbol_);
        __ERC4626_init_unchained(IERC20(underlyingToken_));
        _getSmartAccountWrapperStorage().smartAccount = smartAccount_;
    }

    function allocatedAssets() public view override returns (uint256) {
        return _getSmartAccountWrapperStorage().allocatedAssets;
    }

    function pendingDeallocationAssets() public pure override returns (uint256) {
        return 0;
    }

    function claimableFromStrategies() public pure override returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                               USER LOGIC
    //////////////////////////////////////////////////////////////*/

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        super._deposit(caller, receiver, assets, shares);
        // transfer assets to smart account
        _transferToSmartAccount(assets);
    }

    function requestRedeem(uint256 shares, address controller, address owner)
        public
        override
        whenNotPaused
        returns (uint256 requestId)
    {
        return super.requestRedeem(shares, controller, owner);
    }

    function _transferToSmartAccount(uint256 assets) internal {
        address _smartAccount = smartAccount();
        if (_smartAccount == address(0)) revert SA__SmartAccountNotSet();
        _getSmartAccountWrapperStorage().allocatedAssets += assets;
        IERC20(asset()).safeTransfer(_smartAccount, assets);
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER LOGIC
    //////////////////////////////////////////////////////////////*/

    function forceTransmitAllocatedAssets(uint256 assets) public onlyOwner {
        if (pendingWithdrawals() > 0) revert SA__PendingWithdrawals();
        _getSmartAccountWrapperStorage().allocatedAssets = assets;
        emit AllocatedAssetsTransmitted(assets);
    }

    function forceTransmitDeallocatedAssets(uint256 remainingAllocatedAssets) public onlyOwner {
        if (remainingAllocatedAssets > allocatedAssets() && pendingWithdrawals() > 0) {
            revert SA__PendingWithdrawals();
        }
        _getSmartAccountWrapperStorage().allocatedAssets = remainingAllocatedAssets;
        emit DeallocatedAssetsTransmitted(remainingAllocatedAssets);
    }

    function transmitAllocatedAssets(uint256 assets) public onlySmartAccount {
        if (pendingWithdrawals() > 0) revert SA__PendingWithdrawals();
        _getSmartAccountWrapperStorage().allocatedAssets = assets;
        emit AllocatedAssetsTransmitted(assets);
    }

    function transmitDeallocatedAssets(uint256 remainingAllocatedAssets) public onlySmartAccount {
        uint256 current = allocatedAssets();
        if (remainingAllocatedAssets > current) {
            revert SA__DeallocatedAssetsExceedAllocated(remainingAllocatedAssets, current);
        }
        _getSmartAccountWrapperStorage().allocatedAssets = remainingAllocatedAssets;
        emit DeallocatedAssetsTransmitted(remainingAllocatedAssets);
    }

    function allocateAssets(uint256 assets) public onlyOwner {
        uint256 idle = idleAssets();
        if (assets > idle) revert SA__NotEnoughIdleAssets(assets, idle);
        _transferToSmartAccount(assets);
        emit AssetsAllocated(assets);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function setSmartAccount(address smartAccount_, uint256 allocatedAssets_) public onlyOwner {
        if (smartAccount_ == address(0)) revert SA__ZeroAddress();
        _getSmartAccountWrapperStorage().smartAccount = smartAccount_;
        _getSmartAccountWrapperStorage().allocatedAssets = allocatedAssets_;
        emit SmartAccountSet(smartAccount_);
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE VIEW
    //////////////////////////////////////////////////////////////*/

    function smartAccount() public view returns (address) {
        return _getSmartAccountWrapperStorage().smartAccount;
    }

    /*//////////////////////////////////////////////////////////////
                              ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/
    /// @inheritdoc IERC4626
    function maxDeposit(address) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        address _smartAccount = _getSmartAccountWrapperStorage().smartAccount;
        if (_smartAccount == address(0)) return 0;
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function maxMint(address) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (paused()) return 0;
        address _smartAccount = _getSmartAccountWrapperStorage().smartAccount;
        if (_smartAccount == address(0)) return 0;
        return type(uint256).max;
    }

    function maxRequestRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        return super.maxRequestRedeem(owner);
    }

    /*//////////////////////////////////////////////////////////////
                             ERC-1271 LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates a signature for a given hash
     * @dev Uses OpenZeppelin SignatureChecker which automatically:
     *      - Detects if owner is EOA or contract
     *      - Uses ECDSA recovery for EOA
     *      - Delegates to isValidSignature() for contracts (Safe, etc.)
     * @param hash The hash of the data that was signed
     * @param signature The signature bytes (ECDSA for EOA, or concatenated Safe signatures)
     * @return magicValue 0x1626ba7e if valid, 0xffffffff if invalid
     */
    function isValidSignature(bytes32 hash, bytes calldata signature) external view override returns (bytes4) {
        if (SignatureChecker.isValidSignatureNow(owner(), hash, signature)) {
            return ERC1271_MAGIC_VALUE;
        }
        return ERC1271_INVALID;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC-165 LOGIC
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC7540Redeem).interfaceId
            || interfaceId == type(IERC7540Operator).interfaceId;
    }
}
