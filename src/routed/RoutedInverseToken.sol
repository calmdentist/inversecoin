// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface IRoutedInverseSettlement {
    function inversePaid(address payer, uint256 receiptBefore) external;
    function inverseTaken(address recipient) external;
    function beginPrepayment() external;
    function refundPrepayment() external;
}

/// @dev Standard permissionless Uniswap V4FeeAdapter collection interface.
interface IRoutedProtocolFeeController {
    struct CollectParams {
        Currency currency;
        uint256 amount;
    }
    function collect(CollectParams[] calldata params) external;
}

/// @notice Fixed-share token whose wallet balances follow the market's global denomination index.
/// @dev PoolManager and market are two custody compartments of the same reserve-share account.
/// Native units are exact; custody rounding belongs to that account, never to ordinary holders.
contract RoutedInverseToken is IERC20Metadata {
    using TransientStateLibrary for IPoolManager;
    string public constant name = "Inverse Token";
    string public constant symbol = "INVERSE";
    uint8 public constant decimals = 18;
    uint256 public constant RAY = 1e27;
    uint8 private constant IDLE = 0;
    uint8 private constant LIQUIDITY = 1;
    uint8 private constant USER_SETTLEMENT = 2;
    uint8 private constant FINALIZING = 3;
    uint8 private constant PROTOCOL_COLLECTION = 4;
    address public immutable market;
    address public immutable poolManager;
    uint256 public immutable totalShares;
    uint256 public indexRay = RAY;
    uint256 public workingIndexRay = RAY;
    uint256 public nativeBalance;
    // IDLE -> LIQUIDITY -> USER_SETTLEMENT -> FINALIZING -> IDLE.
    // Prepayment escrow/refund uses FINALIZING while calling the market's guard callbacks.
    // Fee-enabled sells visit PROTOCOL_COLLECTION from FINALIZING before committing the index.
    uint8 public phase;
    bool private buy;
    uint256 private nominal;
    uint256 private nativeAmount;
    uint256 private tradeShares;
    uint256 private receiptInflation;
    uint256 private collectingFee;
    uint256 private collectingShares;
    // Escrow is separate from LP custody and keeps its old denomination until consumed/refunded.
    // A positive hook credit forces either operation before PoolManager can finish its unlock.
    uint256 public prepaidNominal;
    uint256 public prepaidShares;
    mapping(address => uint256) private ownership;
    mapping(address => mapping(address => uint256)) public allowance;

    error Unauthorized();
    error InvalidPhase();
    error InvalidTransfer();
    error InsufficientBalance();
    error InsufficientAllowance();
    error UnbackedInventory();
    error ProtocolFeeCollectionFailed();

    event SharesTransfer(address indexed from, address indexed to, uint256 shares);
    event Rebase(uint256 oldIndexRay, uint256 newIndexRay, uint256 totalShares);
    event CustodyRoundingReclaimed(uint256 nativeUnits);

    constructor(address manager_, uint256 shares_) {
        market = msg.sender;
        poolManager = manager_;
        totalShares = shares_;
        ownership[msg.sender] = shares_;
        emit Transfer(address(0), msg.sender, shares_);
        emit SharesTransfer(address(0), msg.sender, shares_);
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert Unauthorized();
        _;
    }

    function custodiedShares() external view returns (uint256) {
        return ownership[market];
    }

    function sharesOf(address owner) public view returns (uint256) {
        if (owner != poolManager && owner != market) return ownership[owner];
        uint256 bankShares = FullMath.mulDiv(nativeBalance, RAY, workingIndexRay) + prepaidShares;
        if (owner == poolManager) return bankShares;
        return ownership[market] - bankShares;
    }

    function totalSupply() external view returns (uint256) {
        return tokensForShares(totalShares);
    }

    function balanceOf(address owner) public view returns (uint256) {
        if (owner == poolManager) return nativeBalance + receiptInflation + prepaidNominal;
        if (owner == market) {
            return FullMath.mulDiv(ownership[market] - prepaidShares, workingIndexRay, RAY) - nativeBalance;
        }
        return tokensForShares(ownership[owner]);
    }

    function tokensForShares(uint256 shares) public view returns (uint256) {
        return FullMath.mulDiv(shares, indexRay, RAY);
    }

    /// @dev Round upward by less than one raw ownership unit. Index >= RAY makes a full
    /// displayed-balance transfer spend exactly the wallet's shares without an unknown-payer supplement.
    function sharesForTokens(uint256 amount) public view returns (uint256) {
        return FullMath.mulDivRoundingUp(amount, RAY, indexRay);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function transferShares(address to, uint256 shares) external returns (uint256 amount) {
        if (phase != IDLE || to == poolManager) revert InvalidPhase();
        amount = tokensForShares(shares);
        _move(msg.sender, to, shares, amount);
        _checkBacking();
    }

    function beginLiquidity() external onlyMarket {
        if (phase != IDLE) revert InvalidPhase();
        phase = LIQUIDITY;
    }

    /// @dev Only after ALL native positions/claims have been redeemed; market verifies this invariant.
    function resetEmptyCustody(uint256 newIndex) external onlyMarket {
        if (phase != LIQUIDITY || newIndex < RAY) revert InvalidPhase();
        emit CustodyRoundingReclaimed(nativeBalance);
        nativeBalance = 0;
        workingIndexRay = newIndex;
    }

    function arm(bool buy_, uint256 nominal_, uint256 nativeAmount_, uint256 shares_) external onlyMarket {
        if (phase != LIQUIDITY || nominal_ == 0 || shares_ == 0 || nativeAmount_ == 0) revert InvalidPhase();
        buy = buy_;
        nominal = nominal_;
        nativeAmount = nativeAmount_;
        tradeShares = shares_;
        phase = USER_SETTLEMENT;
    }

    /// @dev Hook immediately removes the old/new denomination difference from native custody.
    /// No externally controlled call may occur between this conversion and that custody transfer.
    function consumePrepayment(uint256 amount, uint256 shares) external onlyMarket {
        if (phase != LIQUIDITY || prepaidNominal != amount || prepaidShares != shares || amount == 0) {
            revert InvalidPhase();
        }
        delete prepaidNominal;
        delete prepaidShares;
        nativeBalance += amount;
        phase = FINALIZING;
    }

    function commit() external onlyMarket {
        if (phase != LIQUIDITY && phase != FINALIZING) revert InvalidPhase();
        receiptInflation = 0;
        _checkBacking();
        uint256 old = indexRay;
        indexRay = workingIndexRay;
        phase = IDLE;
        delete nominal;
        delete nativeAmount;
        delete tradeShares;
        emit Rebase(old, indexRay, totalShares);
    }

    /// @notice Pay core INVERSE fees before committing a new denomination.
    /// @dev Requires a permissionless V4FeeAdapter-compatible controller. Every unit must be
    /// collected in this transaction; otherwise the entire trade reverts with no outstanding debt.
    function collectProtocolFees(uint256 maximumShares) external onlyMarket {
        if (phase != FINALIZING) revert InvalidPhase();
        IPoolManager manager = IPoolManager(poolManager);
        uint256 amount = manager.protocolFeesAccrued(Currency.wrap(address(this)));
        if (amount == 0) return;
        uint256 shares = FullMath.mulDivRoundingUp(amount, RAY, workingIndexRay);
        if (shares > maximumShares) revert ProtocolFeeCollectionFailed();
        collectingFee = amount;
        collectingShares = shares;
        phase = PROTOCOL_COLLECTION;
        IRoutedProtocolFeeController.CollectParams[] memory params =
            new IRoutedProtocolFeeController.CollectParams[](1);
        params[0] = IRoutedProtocolFeeController.CollectParams(Currency.wrap(address(this)), amount);
        IRoutedProtocolFeeController(manager.protocolFeeController()).collect(params);
        if (collectingFee != 0 || manager.protocolFeesAccrued(Currency.wrap(address(this))) != 0) {
            revert ProtocolFeeCollectionFailed();
        }
        phase = FINALIZING;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0) || to == address(this) || from == address(0)) revert InvalidTransfer();
        // ERC-20 zero transfers must not create a prepayment or consume an armed settlement.
        if (amount == 0) {
            emit Transfer(from, to, 0);
            return;
        }
        if (from == poolManager || to == poolManager) {
            if (phase == PROTOCOL_COLLECTION) {
                if (
                    msg.sender != poolManager || from != poolManager || to == poolManager || to == market
                        || amount != collectingFee
                ) {
                    revert InvalidTransfer();
                }
                nativeBalance -= amount;
                uint256 shares = collectingShares;
                delete collectingFee;
                delete collectingShares;
                _moveOwnership(market, to, shares);
                emit Transfer(from, to, amount);
                _checkBacking();
                return;
            }
            if (phase == IDLE) {
                _prepayment(from, to, amount);
                return;
            }
            if (phase == LIQUIDITY || phase == FINALIZING) {
                // Only actual hook custody movements, not user settlement, are allowed in these phases.
                if (from == market && to == poolManager && msg.sender == market) {
                    nativeBalance += amount;
                } else if (from == poolManager && to == market && msg.sender == poolManager) {
                    nativeBalance -= amount;
                } else {
                    revert InvalidTransfer();
                }
                _checkBacking();
                emit Transfer(from, to, amount);
                return;
            }
            if (phase != USER_SETTLEMENT || amount != nominal) revert InvalidPhase();
            phase = FINALIZING; // A user leg is single-use, including during its callback.
            if (buy) {
                // PoolManager is a custody compartment, not an ordinary ownership account.
                if (from != poolManager || msg.sender != poolManager || to == market || to == poolManager) {
                    revert InvalidTransfer();
                }
                nativeBalance -= amount;
                _moveOwnership(market, to, tradeShares);
                emit Transfer(poolManager, to, amount);
                IRoutedInverseSettlement(market).inverseTaken(to);
            } else {
                if (to != poolManager || from == market || from == poolManager) revert InvalidTransfer();
                if (amount > balanceOf(from) || sharesForTokens(amount) != tradeShares) {
                    revert InvalidTransfer();
                }
                uint256 beforeReceipt = nativeBalance;
                _moveOwnership(from, market, tradeShares);
                emit Transfer(from, poolManager, amount);
                nativeBalance += nativeAmount;
                receiptInflation = nominal - nativeAmount;
                IRoutedInverseSettlement(market).inversePaid(from, beforeReceipt);
            }
            if (phase != IDLE) revert InvalidPhase();
            return;
        }
        if (phase != IDLE || amount > balanceOf(from)) revert InvalidPhase();
        _move(from, to, sharesForTokens(amount), amount);
        _checkBacking();
    }

    function _prepayment(address from, address to, uint256 amount) private {
        IPoolManager manager = IPoolManager(poolManager);
        if (!manager.isUnlocked()) revert InvalidPhase();
        if (to == poolManager) {
            if (
                from == market || from == poolManager || prepaidNominal != 0 || amount > balanceOf(from)
                    || Currency.unwrap(manager.getSyncedCurrency()) != address(this)
                    || manager.getSyncedReserves() != nativeBalance
            ) revert InvalidTransfer();
            // Do this before changing balanceOf(PoolManager), so the original sync can be restored.
            phase = FINALIZING;
            IRoutedInverseSettlement(market).beginPrepayment();
            uint256 shares = sharesForTokens(amount);
            _moveOwnership(from, market, shares);
            prepaidNominal = amount;
            prepaidShares = shares;
            phase = IDLE;
        } else {
            if (msg.sender != poolManager || to == market || amount != prepaidNominal) {
                revert InvalidTransfer();
            }
            phase = FINALIZING;
            _moveOwnership(market, to, prepaidShares);
            delete prepaidNominal;
            delete prepaidShares;
            IRoutedInverseSettlement(market).refundPrepayment();
            phase = IDLE;
        }
        _checkBacking();
        emit Transfer(from, to, amount);
    }

    function _move(address from, address to, uint256 shares, uint256 amount) private {
        _moveOwnership(from, to, shares);
        emit Transfer(from, to, amount);
    }

    function _moveOwnership(address from, address to, uint256 shares) private {
        if (to == address(0) || to == address(this)) revert InvalidTransfer();
        if (ownership[from] < shares) revert InsufficientBalance();
        ownership[from] -= shares;
        ownership[to] += shares;
        emit SharesTransfer(from, to, shares);
    }

    function _checkBacking() private view {
        if (nativeBalance > FullMath.mulDiv(ownership[market] - prepaidShares, workingIndexRay, RAY)) {
            revert UnbackedInventory();
        }
    }
}
