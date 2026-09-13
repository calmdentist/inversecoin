// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Fixed ownership shares with a globally committed tokens-per-share index.
/// @dev Rebases emit Rebase, not a Transfer for every holder. Integrators must track shares.
contract InverseToken is IERC20Metadata {
    string public constant name = "Inverse Token";
    string public constant symbol = "INVERSE";
    uint8 public constant decimals = 18;
    uint256 public constant RAY = 1e27;

    address public immutable market;
    address public immutable gateway;
    address public immutable poolManager;
    uint256 public immutable totalShares;
    uint256 public indexRay = RAY;
    bool public settlementActive;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(address => uint256)) public shareAllowance;

    error Unauthorized();
    error InvalidAddress();
    error InsufficientShares();
    error InsufficientAllowance();
    error InvalidSettlement();
    error UnrepresentableAmount();

    event SharesTransfer(address indexed from, address indexed to, uint256 shares, uint256 indexRay);
    event SharesApproval(address indexed owner, address indexed spender, uint256 shares);
    event Rebase(uint256 oldIndexRay, uint256 newIndexRay, uint256 totalShares);

    constructor(address market_, address gateway_, address poolManager_, uint256 supply) {
        if (market_ == address(0) || gateway_ == address(0) || poolManager_ == address(0) || supply == 0) {
            revert InvalidAddress();
        }
        market = market_;
        gateway = gateway_;
        poolManager = poolManager_;
        totalShares = supply;
        sharesOf[market_] = supply;
        emit Transfer(address(0), market_, supply);
        emit SharesTransfer(address(0), market_, supply, RAY);
    }

    function totalSupply() external view returns (uint256) {
        return tokensForShares(totalShares);
    }

    function balanceOf(address owner) public view returns (uint256) {
        return tokensForShares(sharesOf[owner]);
    }

    function tokensForShares(uint256 shares) public view returns (uint256) {
        return FullMath.mulDiv(shares, indexRay, RAY);
    }

    function sharesForTokens(uint256 amount) public view returns (uint256) {
        return FullMath.mulDiv(amount, RAY, indexRay);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Share approvals remain stable across rebases and are used by gateway sells.
    function approveShares(address spender, uint256 shares) external returns (bool) {
        shareAllowance[msg.sender][spender] = shares;
        emit SharesApproval(msg.sender, spender, shares);
        return true;
    }

    /// @dev Ordinary token transfers round down to shares. A sub-share nonzero amount reverts.
    /// The actual transferred denomination is emitted; it can differ from `amount` by < one share.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transferTokens(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transferTokens(from, to, amount);
        return true;
    }

    function transferShares(address to, uint256 shares) external returns (uint256 tokens) {
        return _moveShares(msg.sender, to, shares);
    }

    function transferSharesFrom(address from, address to, uint256 shares) external returns (uint256 tokens) {
        uint256 allowed = shareAllowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < shares) revert InsufficientAllowance();
            shareAllowance[from][msg.sender] = allowed - shares;
        }
        return _moveShares(from, to, shares);
    }

    function beginSettlement() external {
        if (msg.sender != market) revert Unauthorized();
        if (settlementActive || sharesOf[poolManager] != 0) revert InvalidSettlement();
        settlementActive = true;
    }

    /// @dev Market derives the index deterministically and calls only after v4 relocks.
    function finishSettlement(uint256 newIndexRay) external {
        if (msg.sender != market) revert Unauthorized();
        if (!settlementActive || sharesOf[poolManager] != 0 || newIndexRay < RAY) revert InvalidSettlement();
        uint256 old = indexRay;
        indexRay = newIndexRay;
        settlementActive = false;
        emit Rebase(old, newIndexRay, totalShares);
    }

    function _transferTokens(address from, address to, uint256 amount) private {
        uint256 shares;
        if (from == poolManager) {
            // v4 must take the ENTIRE frozen-index settlement inventory. Using inverse conversion
            // here could strand one or more shares after floor rounding on the incoming transfer.
            if (msg.sender != poolManager || !settlementActive || amount == 0 || amount != balanceOf(from)) {
                revert InvalidSettlement();
            }
            shares = sharesOf[from];
        } else {
            shares = sharesForTokens(amount);
            if (amount != 0 && shares == 0) revert UnrepresentableAmount();
        }
        _moveShares(from, to, shares);
    }

    function _moveShares(address from, address to, uint256 shares) private returns (uint256 tokens) {
        if (to == address(0) || to == address(this)) revert InvalidAddress();
        if (to == poolManager) {
            if (
                !settlementActive || (msg.sender != gateway && msg.sender != market)
                    || sharesOf[poolManager] != 0 || shares == 0
            ) revert InvalidSettlement();
        }
        if (sharesOf[from] < shares) revert InsufficientShares();
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        tokens = tokensForShares(shares);
        emit Transfer(from, to, tokens);
        emit SharesTransfer(from, to, shares, indexRay);
    }
}
