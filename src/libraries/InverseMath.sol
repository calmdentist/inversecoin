// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @notice Constant product arithmetic in raw shares (18 decimals) and raw quote units.
library InverseMath {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    uint256 internal constant MAX_RESERVE = type(uint112).max;
    uint256 internal constant MAX_DELTA = uint256(uint128(type(int128).max));
    uint256 internal constant MAX_INDEX = 1e45;
    uint256 internal constant MIN_INDEX = 1e9;
    uint256 internal constant MIN_RESERVE_SHARES = 1e9;

    error InvalidAmount();
    error ReserveBounds();
    error IndexBounds();
    error DeltaBounds();

    /// @dev Single final division, as in a conventional integer constant-product AMM.
    /// Output rounds down; fees are retained in actual reserves. The informational fee rounds up.
    function amountOut(uint256 input, uint256 reserveIn, uint256 reserveOut, uint24 fee)
        internal
        pure
        returns (uint256 output, uint256 feeInput)
    {
        if (input == 0 || input > MAX_RESERVE) revert InvalidAmount();
        uint256 effective = input * (FEE_DENOMINATOR - fee);
        output = FullMath.mulDiv(effective, reserveOut, reserveIn * FEE_DENOMINATOR + effective);
        if (output == 0) revert InvalidAmount();
        feeInput = FullMath.mulDivRoundingUp(input, fee, FEE_DENOMINATOR);
    }

    /// @dev Calculate P/P0 directly from reserves, avoiding a rounded P0 in the denominator.
    function index(uint256 x, uint256 y, uint256 initialX, uint256 initialY)
        internal
        pure
        returns (uint256 result)
    {
        if (x < MIN_RESERVE_SHARES || x > initialX || y == 0 || y > MAX_RESERVE) {
            revert ReserveBounds();
        }
        result = indexOrZero(x, y, initialX, initialY);
        if (result == 0) revert IndexBounds();
    }

    /// @dev Zero indicates a state unsuitable for trading. LP redemption must remain possible there.
    function indexOrZero(uint256 x, uint256 y, uint256 initialX, uint256 initialY)
        internal
        pure
        returns (uint256 result)
    {
        if (x < MIN_RESERVE_SHARES || x > initialX || y == 0 || y > MAX_RESERVE) return 0;
        uint256 relativePrice = FullMath.mulDiv(y, initialX * RAY, x * initialY);
        // Bound before squaring. Never clamp the index: the entire trade reverts.
        // LP withdrawals release shares that can be sold below the launch price.
        if (relativePrice < 1e18 || relativePrice > 1e36) return 0;
        result = FullMath.mulDiv(relativePrice, relativePrice, RAY);
        if (result > MAX_INDEX || result > FullMath.mulDiv(MAX_DELTA, RAY, initialX)) {
            return 0;
        }
    }

    function toInt128(uint256 value) internal pure returns (int128) {
        if (value == 0 || value > MAX_DELTA) revert DeltaBounds();
        return int128(uint128(value));
    }
}
