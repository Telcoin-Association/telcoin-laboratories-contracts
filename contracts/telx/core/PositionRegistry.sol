// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IPositionRegistry, PoolId} from "../interfaces/IPositionRegistry.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager, PoolKey, PositionInfo} from "../interfaces/IPositionManager.sol";

// todo: refactor, reauthor:
// this contract doesn't need to store unsubscribedTokenIds or positions at all; fetch from positionManager
// this contract should store participating tokenIds, written at subscribe time
// this contract should store fee tracking information (tokenId => fees), written at modifyLiquidity and addRewards time 
//   - checkpointing
// offchain script can then pull fee tracking info and calculate final checkpoint subperiod
// during addRewards, final checkpoint should be written to align all subscribed positions checkpoints at period endBlock

/**
 * @title Position Registry
 * @author Robriks 📯️📯️📯️.eth
 * @notice Tracks Uniswap V4 LP fees for positions subscribed to the TELxIncentives program and manages off-chain reward distribution.
 * @dev Emits events during Uniswap V4 hook actions and stores fee checkpoints for consumption by an off-chain reward calculation system.
 */
contract PositionRegistry is IPositionRegistry, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    bytes32 public constant UNI_HOOK_ROLE = keccak256("UNI_HOOK_ROLE");
    bytes32 public constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");
    bytes32 public constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");

    uint256 constant MAX_POSITIONS = 100; //todo: this can be increased due to refactor efficiency

    mapping(address => uint256[]) public providerTokenIds;
    mapping(address => uint256[]) public unsubscribedTokenIds;
    mapping(address => uint256) public unclaimedRewards;
    mapping(uint256 => Position) public positions;
    mapping(PoolId => PoolKey) public initializedPoolKeys;
    mapping(address => bool) public routers;

    //todo: refactored state
    uint256 currentPeriod;
    /// @notice The current set of active participating positions subscribed to TELxIncentives
    uint256[] public subscriptions;
    /// @notice History of positions' fee information: `tokenId => {block, telDenominatedFees}`
    /// @dev Since Trace224 array is unbounded it can grow beyond EVM memory limits
    /// do not load into EVM memory; consume offchain instead
    mapping(uint256 => Checkpoints.Trace224) private feeRecords;
    //todo: view function to fetch feeRecords
    /// @notice Maps period numbers to their end block
    mapping(uint256 => uint32) public periodEndBlock;

    IERC20 public immutable telcoin;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    /**
     * @notice Initializes the registry with a reward token
     * @param _telcoin The ERC20 token used to pay LP rewards
     */
    constructor(IERC20 _telcoin, IPoolManager _poolManager, IPositionManager _positionManager) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        telcoin = _telcoin;
        poolManager = _poolManager;
        positionManager = _positionManager;
    }

    /**
     * @notice Returns whether a given PoolId is known by this contract
     * @dev A PoolId is considered valid if it has been initialized with a currency pair.
     * @param id The unique identifier for the Uniswap V4 pool.
     * @return True if the pool has a non-zero currency0 or currency1 address.
     */
    function validPool(PoolId id) public view override returns (bool) {
        address currency0 = Currency.unwrap(initializedPoolKeys[id].currency0);
        address currency1 = Currency.unwrap(initializedPoolKeys[id].currency1);
        if (currency0 != address(0x0) || currency1 != address(0x0)) {
            return true;
        }

        return false;
    }

    /**
     * @notice Returns position metadata given its ID
     */
    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return positions[tokenId];
    }

    /**
     * @notice Returns positionIds for a Provider
     */
    function getTokenIdsByProvider(address provider) external view override returns (uint256[] memory) {
        return providerTokenIds[provider];
    }

    /**
     * @notice Returns positionIds for a Provider that have not been subscribed
     */
    function getUnsubscribedTokenIdsByProvider(address provider) external view override returns (uint256[] memory) {
        return unsubscribedTokenIds[provider];
    }

    /**
     * @notice Returns whether a router is in the trusted routers list.
     * @dev Used to determine if a router can be queried for the actual msg.sender.
     * @param router The address of the router to query.
     * @return True if the router is listed as trusted.
     */
    function isActiveRouter(address router) public view override returns (bool) {
        return routers[router];
    }

    /**
     * @notice Gets unclaimed reward balance for a user
     */
    function getUnclaimedRewards(address user) external view returns (uint256) {
        return unclaimedRewards[user];
    }

    /**
     * @notice Returns the voting weight (in TEL) for a position at a given sqrtPriceX96
     * @dev Because voting weight is TEL-denominated, it fluctuates with price changes & impermanent loss
     * The spec uses TEL denomination rather than liquidity units for backwards compatibility with
     * Snapshot infra + preexisting integration modules like VotingWeightCalculator & UniswapAdaptor
     * @param tokenId The position identifier
     */
    function computeVotingWeight(uint256 tokenId) external view returns (uint256) {
        // todo: from here until getAmountsForLiquidity can be replaced with the getAmountsForLiquidity(tokenId)
        Position storage pos = positions[tokenId];
        if (pos.liquidity == 0) return 0;

        // todo: this should be replaced by a call to getPoolAndPositionInfo()
        if (pos.provider != IPositionManager(positionManager).ownerOf(tokenId)) {
            return 0;
        }

        PoolId poolId = positions[tokenId].poolId;
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper),
            pos.liquidity
        );

        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 2 ** 96);

        // todo: refactor to currency0 and currency1, incorporating price quote/calculation for stablecoin (nonTEL) pools
        PoolKey memory key = initializedPoolKeys[pos.poolId];
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        uint8 telIndex = currency0 == address(telcoin) ? 0 : currency1 == address(telcoin) ? 1 : 2;
        if (telIndex == 2) {
            //todo this is a nonTEL pool; we need to get price of both token0 and token1 in TEL via quote
        }

        if (telIndex == 0) {
            return amount0 + FullMath.mulDiv(amount1, 2 ** 96, priceX96);
        } else if (telIndex == 1) {
            return amount1 + FullMath.mulDiv(amount0, priceX96, 2 ** 96);
        }

        return 0;
    }

    //todo: add external view function getAmountsForLiquidity(tokenId) returns both token amounts at current tick

    /**
     * @notice Computes the amounts of token0 and token1 for given liquidity and prices
     * @dev Used for Uniswap V3/V4 style liquidity math
     */ //todo: _getAmountsForLiquidity()
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            uint256 intermediate = FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96);
            amount0 = FullMath.mulDiv(intermediate, 1 << 96, sqrtPriceAX96);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint256 intermediate = FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceX96, sqrtPriceBX96);
            amount0 = FullMath.mulDiv(intermediate, 1 << 96, sqrtPriceX96);

            amount1 = FullMath.mulDiv(liquidity, sqrtPriceX96 - sqrtPriceAX96, FixedPoint96.Q96);
        } else {
            amount1 = FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
        }
    }

    /**
     * @notice Updates the stored index of TEL in a specific Uniswap V4 pool.
     * @dev Only callable by the TELxIncentiveHook which possesses `UNI_HOOK_ROLE`
     * @dev Must be initiated by an admin as `tx.origin`
     */
    function initialize(address sender, PoolKey calldata key) external onlyRole(UNI_HOOK_ROLE) {
        require(hasRole(DEFAULT_ADMIN_ROLE, _resolveUser(sender)), "PositionRegistry: Only admin can initialize pools with this hook");
        require(!validPool(key.toId()), "PositionRegistry: Pool already initialized");
        initializedPoolKeys[key.toId()] = key;

        emit PoolAdded(key);
    }

    /**
     * @notice Adds or removes a router from the trusted routers registry.
     * @dev Only callable by an address with SUPPORT_ROLE.
     * @param router The router address to update.
     * @param listed Whether the router should be marked as trusted.
     */
    function updateRegistry(address router, bool listed) external onlyRole(SUPPORT_ROLE) {
        routers[router] = listed;
        emit RouterRegistryUpdated(router, listed);
    }

    /**
     * @notice Called by Uniswap hook to add or remove tracked liquidity
     * @param tokenId The identifier of the position to remove.
     * @param poolId Target pool
     * @param liquidityDelta Change in liquidity (positive = add, negative = remove)
     */
    function addOrUpdatePosition(uint256 tokenId, PoolId poolId, int128 liquidityDelta)
        external
        onlyRole(UNI_HOOK_ROLE)
    {
        //todo: this function should instead write a fee tracking checkpoint (modifyLiquidity time)
        // if (isSubscribed) it should check that the tokenId's owner is still staked on TELx plugin
        // it does not need to check that the tokenId is still subscribed (because of handleUnsubscribe during unsubscribes or transfers)
        // it should identify fees being collected and store it using an internal setter which is also used during addRewards()

        // Does not fail on invalid poolId, just skips update
        if (!validPool(poolId)) {
            return;
        }

        require(tokenId != 0, "PositionRegistry: Only NFT-backed positions supported");

        require(liquidityDelta != type(int128).min, "PositionRegistry: Invalid liquidity delta");

        Position storage pos = positions[tokenId];

        address tokenOwner; 
        try IPositionManager(positionManager).ownerOf(tokenId) returns (address lp) {
            tokenOwner = lp;
        } catch {}

        // If the position does not exist, we expect the owner to call `subscribe`
        if (pos.provider == address(0)) {
            if (
                unsubscribedTokenIds[tokenOwner].length <= MAX_POSITIONS
                    && providerTokenIds[tokenOwner].length <= MAX_POSITIONS
            ) {
                unsubscribedTokenIds[tokenOwner].push(tokenId);
            }
            return;
        }

        // The token is being burned
        // You can get to a liquidity 0 state without burning the token
        // using DECREASE operations but the token will still exist and have
        // an owner.
        if (tokenOwner == address(0)) {
            _removePosition(tokenId, pos.provider, poolId, pos.tickLower, pos.tickUpper);
            return;
        }

        // If the position does exist, we need to make sure the owner didn't change. Otherwise
        // we require the new owner to also call `subscribe`
        if (pos.provider != tokenOwner) {
            return;
        }

        if (liquidityDelta > 0) {
            pos.liquidity += uint128(liquidityDelta);
        } else {
            // the case where `liquidityDelta == 0` is permitted, though it has no effect beyond gas spend
            uint128 delta = uint128(-liquidityDelta);
            require(pos.liquidity >= delta, "PositionRegistry: Insufficient liquidity");
            pos.liquidity -= delta;
        }

        emit PositionUpdated(tokenId, pos.provider, poolId, pos.tickLower, pos.tickUpper, uint128(pos.liquidity));
    }

    /**
     * @notice Internally removes a position from both the provider and global registries.
     * @param tokenId The identifier of the position to remove.
     * @param provider The address of the LP whose position is now subscribed.
     */
    function _removeUnsubscribedPosition(uint256 tokenId, address provider) internal {
        uint256[] storage list = unsubscribedTokenIds[provider];
        for (uint256 j = 0; j < list.length; j++) {
            if (list[j] == tokenId) {
                list[j] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    /**
     * @notice Internally removes a position from both the provider and global registries.
     * @dev Deletes the position mapping, removes from providerPositions arrays.
     *      Emits a PositionRemoved event.
     * @param tokenId The identifier of the position to remove.
     * @param provider The address of the LP whose position is being removed.
     * @param poolId The pool associated with the position.
     * @param tickLower The lower tick boundary of the position.
     * @param tickUpper The upper tick boundary of the position.
     */
    function _removePosition(uint256 tokenId, address provider, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
    {
        delete positions[tokenId];

        uint256[] storage list = providerTokenIds[provider];
        for (uint256 j = 0; j < list.length; j++) {
            if (list[j] == tokenId) {
                list[j] = list[list.length - 1];
                list.pop();
                break;
            }
        }

        emit PositionRemoved(tokenId, provider, poolId, tickLower, tickUpper);
    }

    /**
     * @notice Registers a position's ownership using the NFT tokenId.
     * @dev Must be invoked during hooks by an address with SUBSCRIBER_ROLE, such as TELxSubscriber
     *      Reads the existing position metadata, and updates LP position ownership if necessary
     * @dev LPs must call `PositionManager::subscribe()` to graduate unsubscribed (new) positions to active tracking
     * @param tokenId The NFT tokenId corresponding to the original position.
     */
    function handleSubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        // todo: make call to stakingPlugin() to check for stake and only LPs that are staked in TELx will return voting weight and qualify for rewards
        require(tokenId != 0, "PositionRegistry: Invalid tokenId");
        // todo: approved can also call this not just owner; are there conditions where reverting here causes problem
        address newOwner = IPositionManager(positionManager).ownerOf(tokenId);

        (PoolKey memory poolKey, PositionInfo info) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();

        // Skip if not a known TEL pool registered by `SUPPORT_ROLE`
        if (!validPool(poolId)) {
            return;
        }

        Position storage pos = positions[tokenId];

        // No change in ownership
        // Liquidity should be updated via addOrUpdatePosition actions anyway due to the hook.
        if (pos.provider == newOwner) {
            //todo: this represents case where subscribe is called again on an already subscribed position
            // if handleUnsubscribe updates transferred positions, `pos.provider == newOwner` is unnecessary
            // and can be changed to `pos.provider != address(0)` to no-op re-subscriptions
            return;
        }

        if (pos.provider == address(0)) {
            // new position; emit the event for offchain availability & remove from unsubscribed state
            _removeUnsubscribedPosition(tokenId, newOwner);
            emit Subscribed(tokenId, newOwner);
        } else { //todo: logic in this branch should be handled by handleUnsubscribe()
            // known position (subscribed) ownership change; remove the position from the old LP
            _removePosition(tokenId, pos.provider, poolId, pos.tickLower, pos.tickUpper);
        }

        // add position state to new owner's tracked state
        uint128 liquidity = IPositionManager(positionManager).getPositionLiquidity(tokenId);
        positions[tokenId] = Position({
            provider: newOwner,
            poolId: poolId,
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            liquidity: liquidity
        });

        if (providerTokenIds[newOwner].length <= MAX_POSITIONS) {
            providerTokenIds[newOwner].push(tokenId);
            emit PositionUpdated(tokenId, newOwner, poolId, info.tickLower(), info.tickUpper(), liquidity);
        }
    }

    /**
     * @notice Deregisters a position.
     * @dev Must be invoked during hooks by an address with SUBSCRIBER_ROLE, such as TELxSubscriber
     *      Invoked during v4 unsubscription hooks during LP token transfers 
     *      Reads the existing position metadata, removes it from the old provider, and reassigns it to the new owner.
     * @param tokenId The NFT tokenId corresponding to the original position.
     */
    function handleUnsubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        //todo: double check this is not invoked during burns
        require(tokenId != 0, "PositionRegistry: Invalid tokenId");
        address newOwner = IPositionManager(positionManager).ownerOf(tokenId);

        (PoolKey memory poolKey, PositionInfo info) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();

        // Skip if not a known TEL pool registered by `SUPPORT_ROLE`
        if (!validPool(poolId)) {
            return;
        }

        Position storage pos = positions[tokenId];

        // no change in ownership implies this is a self transfer or a direct call to unsubscribe()
        if (pos.provider == newOwner) {
            return;
        }
    }

    /**
     * @notice Adds batch rewards for many users in a specific block round
     * @param providers LP addresses
     * @param amounts Reward values per address
     * @param totalAmount Sum of all `amounts`
     */
    function addRewards(address[] calldata providers, uint256[] calldata amounts, uint256 totalAmount)
        external
        nonReentrant
        onlyRole(SUPPORT_ROLE)
    {
        require(providers.length == amounts.length, "PositionRegistry: Length mismatch");

        telcoin.safeTransferFrom(_msgSender(), address(this), totalAmount);

        uint256 total = 0;
        for (uint256 i = 0; i < providers.length; i++) {
            unclaimedRewards[providers[i]] += amounts[i];
            total += amounts[i];
            emit RewardsAdded(providers[i], amounts[i]);
        }

        require(total == totalAmount, "PositionRegistry: Total amount mismatch");
    }

    /**
     * @notice Allows users to claim their earned rewards
     */
    function claim() external nonReentrant {
        uint256 reward = unclaimedRewards[_msgSender()];
        require(reward > 0, "PositionRegistry: No claimable rewards");

        unclaimedRewards[_msgSender()] = 0;
        telcoin.safeTransfer(_msgSender(), reward);

        emit RewardsClaimed(_msgSender(), reward);
    }

    //todo delete
    // function removeUnsubscribedPosition(uint256 tokenId, address provider) external onlyRole(SUPPORT_ROLE) {
    //     _removeUnsubscribedPosition(tokenId, provider);
    // }

    /**
     * @notice Resolves the actual user address from the swap initiator
     * @dev If the sender is a trusted router, attempts to call `msgSender()` on the router to get the original user (EOA or smart account).
     *      Reverts if the router is trusted but does not implement the `msgSender()` function.
     *      If the sender is not a trusted router, it is assumed to be the actual user and returned directly.
     * @param sender Address passed to the hook by the PoolManager (typically a router or user)
     * @return user Resolved user address — either the EOA from a router or the direct sender
     */
    function _resolveUser(address sender) internal view returns (address) {
        if (isActiveRouter(sender)) {
            try IMsgSender(sender).msgSender() returns (address user) {
                return user;
            } catch {
                revert("Trusted router must implement msgSender()");
            }
        }
        return sender;
    }

    /**
     * @notice Admin function to recover ERC20 tokens sent to contract in error
     */
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external onlyRole(SUPPORT_ROLE) {
        token.safeTransfer(destination, amount);
    }
}
