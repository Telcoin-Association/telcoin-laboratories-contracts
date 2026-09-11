// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {TELxPools} from "../shared/TELxPools.sol";
import {V4PoolMath} from "../shared/V4PoolMath.sol";
import {TELxPoolScriptBase} from "./TELxPoolScriptBase.sol";

/**
 * @title SeedV4Liquidity
 * @notice Mints the initial liquidity position into a standardized TELx Uniswap v4 pool, either
 *         full range or across a percentage band around the current price.
 * @dev    The proposal asks for both shapes: concentrated liquidity as the primary form for
 *         capital efficiency, and a full-range position as a secondary backstop so the pool still
 *         quotes if price leaves the tight band. Both are the same call with a different
 *         `widthBps`, so seeding a pool with one of each is two runs of this script.
 *
 *         Usage - preview first, it broadcasts nothing:
 *
 *           forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
 *             --rpc-url $POLYGON_RPC_URL \
 *             --sig "plan(string,uint256,uint256,uint16)" \
 *             "POLYGON_EUSD_TEL" 100000 20000000 1000
 *
 *         Then seed:
 *
 *           forge script script/telx/SeedV4Liquidity.s.sol:SeedV4Liquidity \
 *             --rpc-url $POLYGON_RPC_URL --broadcast \
 *             --sig "run(string,uint256,uint256,uint16)" \
 *             "POLYGON_EUSD_TEL" 100000 20000000 1000
 *
 *         `widthBps` is the half-width of the band in basis points: 1000 is +/-10%, and 0 means
 *         full range. Amounts are whole tokens.
 *
 *         Note that the amounts are a ceiling, not a target. `getLiquidityForAmounts` takes the
 *         binding side of the pair, so one currency is typically deposited in full and the other
 *         partially; the plan output shows exactly how much of each will move.
 */
contract SeedV4Liquidity is TELxPoolScriptBase {
    /// @notice `widthBps == 0` selects the full range rather than a band of zero width.
    uint16 internal constant FULL_RANGE = 0;

    /// @dev How long the Permit2 allowance and the mint deadline stay valid. Long enough to
    ///      survive a slow hardware-wallet confirmation, short enough that a stale approval is not
    ///      left standing.
    uint256 internal constant VALIDITY_WINDOW = 30 minutes;

    error PoolNotInitialized(string poolName);
    error NothingToMint();

    struct SeedPlan {
        PoolKey key;
        PoolId poolId;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0Max;
        uint256 amount1Max;
        uint256 amount0Used;
        uint256 amount1Used;
    }

    // -----------
    // Preview
    // -----------

    /**
     * @notice Dry run. Resolves and prints the ticks, liquidity and the amounts that would actually
     *         move, and broadcasts nothing.
     */
    function plan(string memory poolName, uint256 amount0Human, uint256 amount1Human, uint16 widthBps) public view {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);

        console2.log("=== SeedV4Liquidity plan ===");
        console2.log("Chain:      ", config.name);

        // Allow a projection so the whole sequence can be rehearsed before the pool exists: an
        // uninitialized pool has no price to seed against, but CreateV4Pool would open it at the
        // price these same amounts imply, so that is what the preview shows.
        (SeedPlan memory p, bool projected) =
            _buildPlan(config, s, poolName, amount0Human, amount1Human, widthBps, true);

        _logPool(poolName, s, p.key);
        console2.log(projected ? "Projected price (pool not yet created):" : "Current price:");
        _logPrice(p.sqrtPriceX96);
        console2.log(widthBps == FULL_RANGE ? "Range: FULL" : "Range: concentrated");
        if (widthBps != FULL_RANGE) console2.log("  widthBps:", uint256(widthBps));
        _logRange(p.tickLower, p.tickUpper, s.tickSpacing);
        console2.log("Liquidity:", uint256(p.liquidity));
        console2.log("Authorized (raw):");
        console2.log("  amount0Max:", p.amount0Max);
        console2.log("  amount1Max:", p.amount1Max);
        console2.log("Will actually deposit (raw):");
        console2.log("  amount0:", p.amount0Used);
        console2.log("  amount1:", p.amount1Used);
    }

    // -----------
    // Run
    // -----------

    /// @notice Production entrypoint. Resolves the signer from env and delegates.
    function run(string memory poolName, uint256 amount0Human, uint256 amount1Human, uint16 widthBps)
        external
        returns (uint256 tokenId)
    {
        return runWithSigner(poolName, amount0Human, amount1Human, widthBps, _resolveSigner());
    }

    /**
     * @notice Explicit-signer entrypoint. Production `run()` delegates here and fork tests call it
     *         directly with a controlled signer, per the repo's deploy-script convention.
     * @param poolName A `CHAIN_SYMBOL0_SYMBOL1` name from the TELx catalog.
     * @param amount0Human Whole tokens of currency0 to authorize.
     * @param amount1Human Whole tokens of currency1 to authorize.
     * @param widthBps Half-width of the band in basis points, or 0 for full range.
     * @param signer Address to broadcast from; also the recipient of the position NFT.
     * @return tokenId The minted position's NFT id.
     */
    function runWithSigner(
        string memory poolName,
        uint256 amount0Human,
        uint256 amount1Human,
        uint16 widthBps,
        address signer
    ) public returns (uint256 tokenId) {
        ChainConfig memory config = _chainConfig();
        TELxPools.PoolSpec memory s = _poolSpec(poolName);

        (SeedPlan memory p,) = _buildPlan(config, s, poolName, amount0Human, amount1Human, widthBps, false);
        if (p.liquidity == 0) revert NothingToMint();

        _logPool(poolName, s, p.key);
        _logRange(p.tickLower, p.tickUpper, s.tickSpacing);

        IPositionManager positionManager = IPositionManager(config.positionManager);

        // The position NFT id is assigned sequentially, so the one we are about to mint is the
        // current counter. Read it before broadcasting so the value can be reported and checked.
        tokenId = positionManager.nextTokenId();

        vm.startBroadcast(signer);
        _approve(config, s, p);
        positionManager.modifyLiquidities{value: _nativeValue(s, p)}(
            _encodeMint(s, p, signer), block.timestamp + VALIDITY_WINDOW
        );
        vm.stopBroadcast();

        _postConditions(positionManager, tokenId, signer, p);

        console2.log("Position minted.");
        console2.log("  tokenId:  ", tokenId);
        console2.log("  liquidity:", uint256(p.liquidity));
    }

    // -----------
    // Plan construction
    // -----------

    /// @param allowProjected When the pool does not exist yet, derive the price from the amounts
    ///        instead of reverting. Only the preview sets this; a real seed must never invent a
    ///        price.
    /// @return p The resolved plan.
    /// @return projected True when the price was derived rather than read from the chain.
    function _buildPlan(
        ChainConfig memory config,
        TELxPools.PoolSpec memory s,
        string memory poolName,
        uint256 amount0Human,
        uint256 amount1Human,
        uint16 widthBps,
        bool allowProjected
    ) internal view returns (SeedPlan memory p, bool projected) {
        p.key = TELxPools.poolKey(s);
        p.poolId = p.key.toId();

        p.amount0Max = V4PoolMath.toRawAmount(amount0Human, s.decimals0);
        p.amount1Max = V4PoolMath.toRawAmount(amount1Human, s.decimals1);

        // Seed against the pool's live price, never a recomputed one: if the pool has already
        // traded, minting at our own idea of the price would place the position off-market.
        p.sqrtPriceX96 = _currentSqrtPriceX96(config, p.poolId);
        if (p.sqrtPriceX96 == 0) {
            if (!allowProjected) revert PoolNotInitialized(poolName);
            projected = true;
            p.sqrtPriceX96 = V4PoolMath.sqrtPriceX96FromAmounts(p.amount0Max, p.amount1Max);
        }

        (p.tickLower, p.tickUpper) = widthBps == FULL_RANGE
            ? V4PoolMath.fullRangeTicks(s.tickSpacing)
            : V4PoolMath.percentRangeTicks(p.sqrtPriceX96, widthBps, s.tickSpacing);

        // Derive the sqrt-price bounds from the SAME ticks the position will be minted at. Any
        // other pairing computes liquidity for a range the position does not span.
        (uint160 sqrtLower, uint160 sqrtUpper) = V4PoolMath.sqrtPricesAtTicks(p.tickLower, p.tickUpper);

        p.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            p.sqrtPriceX96, sqrtLower, sqrtUpper, p.amount0Max, p.amount1Max
        );
        (p.amount0Used, p.amount1Used) =
            LiquidityAmounts.getAmountsForLiquidity(p.sqrtPriceX96, sqrtLower, sqrtUpper, p.liquidity);
    }

    // -----------
    // Approvals
    // -----------

    /**
     * @dev Uniswap v4 pulls ERC-20s through Permit2, which needs two steps per token: an ordinary
     *      ERC-20 approval to Permit2, then a Permit2 allowance for the PositionManager.
     *
     *      Both are for the exact authorized amount with a real expiry, not `type(uint160).max` and
     *      `type(uint48).max`. The repo's convention is exact-amount approvals, and it matters more
     *      here than in a test: this runs against mainnet from a treasury-funded signer, so a
     *      standing unlimited allowance to Permit2 would outlive the deploy.
     *
     *      Native ETH needs neither step; it is sent as call value instead.
     */
    function _approve(ChainConfig memory config, TELxPools.PoolSpec memory s, SeedPlan memory p) internal {
        uint48 expiration = uint48(block.timestamp + VALIDITY_WINDOW);

        if (!TELxPools.isNativeCurrency0(s)) {
            _approveOne(config, s.currency0, p.amount0Max, expiration);
        }
        _approveOne(config, s.currency1, p.amount1Max, expiration);
    }

    function _approveOne(ChainConfig memory config, address token, uint256 amount, uint48 expiration) internal {
        IERC20(token).approve(config.permit2, amount);
        IAllowanceTransfer(config.permit2).approve(token, config.positionManager, uint160(amount), expiration);
    }

    /**
     * @dev Native ETH is settled as call value, and the value sent must be the authorized ceiling
     *      rather than the computed `amount0Used`.
     *
     *      `getAmountsForLiquidity` rounds down, because it answers "what is this position worth".
     *      Minting asks the opposite question, "what does this position cost", and rounds up. The
     *      two differ by a wei or two, so sending exactly `amount0Used` leaves `settle` short and
     *      the whole unlock callback reverts. Sending `amount0Max` covers the rounding, and the
     *      SWEEP action in `_encodeMint` returns everything unspent to the recipient in the same
     *      transaction, so the ceiling is never actually at risk.
     */
    function _nativeValue(TELxPools.PoolSpec memory s, SeedPlan memory p) internal pure returns (uint256) {
        return TELxPools.isNativeCurrency0(s) ? p.amount0Max : 0;
    }

    // -----------
    // Action encoding
    // -----------

    /**
     * @dev Encodes MINT_POSITION followed by SETTLE_PAIR, plus SWEEP when currency0 is native ETH.
     *
     *      SETTLE_PAIR pays what the mint owes on both currencies. SWEEP is only needed on the
     *      native leg: `amount0Used` is a rounded figure, so the call can be left holding a few wei
     *      that would otherwise stay in the PositionManager. ERC-20 legs need no sweep because
     *      nothing is pre-sent; Permit2 pulls exactly what is owed.
     */
    function _encodeMint(TELxPools.PoolSpec memory s, SeedPlan memory p, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        bool native = TELxPools.isNativeCurrency0(s);

        bytes memory actions = native
            ? abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP))
            : abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](native ? 3 : 2);
        params[0] = abi.encode(
            p.key,
            p.tickLower,
            p.tickUpper,
            uint256(p.liquidity),
            // Slippage ceilings. The authorized amounts are the right bound: they are what the
            // operator signed off on, and the mint consumes at most that much by construction.
            uint128(p.amount0Max),
            uint128(p.amount1Max),
            recipient,
            bytes("")
        );
        params[1] = abi.encode(p.key.currency0, p.key.currency1);
        if (native) {
            params[2] = abi.encode(Currency.wrap(TELxPools.NATIVE), recipient);
        }

        return abi.encode(actions, params);
    }

    // -----------
    // Post-conditions
    // -----------

    /// @dev Confirms on chain that the position exists, belongs to the signer and holds the
    ///      liquidity we intended, rather than trusting that the batched call did what we encoded.
    function _postConditions(IPositionManager positionManager, uint256 tokenId, address signer, SeedPlan memory p)
        internal
        view
    {
        require(positionManager.getPositionLiquidity(tokenId) == p.liquidity, "Post-check: liquidity mismatch");

        (PoolKey memory mintedKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        require(PoolId.unwrap(mintedKey.toId()) == PoolId.unwrap(p.poolId), "Post-check: minted into the wrong pool");
        // The PositionManager is itself the position ERC-721.
        require(
            IERC721(address(positionManager)).ownerOf(tokenId) == signer, "Post-check: unexpected position owner"
        );
    }
}
