// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @title MockPositionManager
/// @notice Minimal stand-in for the Uniswap v4 PositionManager exposing only the surface the thin
///         PositionRegistry reads: `getPoolAndPositionInfo`, `getPositionLiquidity`, and the
///         ERC721 `ownerOf`. Each tokenId's data is set explicitly so registry branches can be
///         exercised deterministically without a mainnet fork.
/// @dev Cast to `IPositionManager` by the registry; only the three selectors above are dispatched.
contract MockPositionManager {
    struct MockPosition {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address owner;
        bool exists;
    }

    mapping(uint256 => MockPosition) private _positions;

    /// @notice Registers a position so registry view shims and the subscribe flow can read it.
    function setPosition(
        uint256 tokenId,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address owner
    ) external {
        _positions[tokenId] = MockPosition(poolKey, tickLower, tickUpper, liquidity, owner, true);
    }

    /// @notice Adjusts a position's live liquidity (e.g. to simulate a drain below threshold).
    function setLiquidity(uint256 tokenId, uint128 liquidity) external {
        _positions[tokenId].liquidity = liquidity;
    }

    /// @notice Changes a position's owner of record (e.g. to simulate a transfer).
    function setOwner(uint256 tokenId, address owner) external {
        _positions[tokenId].owner = owner;
    }

    /// @notice Simulates a burn: `ownerOf` reverts and liquidity reads zero afterwards.
    function burn(uint256 tokenId) external {
        delete _positions[tokenId];
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, PositionInfo) {
        MockPosition storage p = _positions[tokenId];
        return (p.poolKey, PositionInfoLibrary.initialize(p.poolKey, p.tickLower, p.tickUpper));
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        return _positions[tokenId].liquidity;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(_positions[tokenId].exists, "MockPositionManager: nonexistent token");
        return _positions[tokenId].owner;
    }
}
