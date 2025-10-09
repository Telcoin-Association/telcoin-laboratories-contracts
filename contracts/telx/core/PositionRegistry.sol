// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPositionRegistry, PoolId} from "../interfaces/IPositionRegistry.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";

import {IPositionManager, PoolKey, PositionInfo} from "../interfaces/IPositionManager.sol";

// todo: refactor, reauthor:
// this contract should store participating tokenIds, written at subscribe time
// this contract should store fee tracking information (tokenId => fees), written at modifyLiquidity and addRewards time 
//   - checkpointing
// offchain script can then pull fee tracking info and calculate final checkpoint subperiod
// during addRewards, final checkpoint should be written to align all subscribed positions checkpoints at period endBlock
// update spec.md -> README.md and incorporate google doc to current markdown

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
    /// @dev Marks positions either burned or not created via PositionManager
    address constant UNTRACKED = address(type(uint160).max);

    //todo: refactored state
    mapping(address => bool) public routers; //todo: necessary? just set universal router as immutable
    mapping(PoolId => PoolKey) public initializedPoolKeys;
    
    /// @notice Mapping to track all positions associated with supported pools
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public ownerPositions;
    mapping(uint256 => CheckpointMetadata) public positionMetadata;
    
    /// @notice The current set of active positions participating in TELxIncentives program via subscription
    uint256[] public subscriptions;
    mapping(address => uint256[]) public subscribedTokenIds;
    mapping(address => uint256) public unclaimedRewards;
    
    //todo: view function to fetch liquidityModifications
    //todo: should this contract support multiple poolIds or be deployed per-pool? must be enforced
    
    /// @notice Maps period numbers to their end block
    mapping(uint256 => uint32) public periodEndBlock;
    uint256 public currentPeriod;

    IERC20 public immutable telcoin;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    StateView public immutable stateView;

    constructor(IERC20 telcoin_, IPoolManager poolManager_, IPositionManager positionManager_, StateView stateView_) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        telcoin = telcoin_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        stateView = stateView_;
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

    // /**
    //  * @notice Returns position metadata given its ID
    //  */
    // function getPosition(uint256 tokenId) external view returns (Position memory) {
    //     return positions[tokenId];
    // } //todo: delete

    /**
     * @notice Returns tokenIds for an owner that have been subscribed
     */
    function getSubscribedTokenIdsByOwner(address owner) external view override returns (uint256[] memory) {
        return ownerPositions[owner]; //todo function to loop through subscribedTokenIds and filter by owner address
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
     * @notice Returns the voting weight (in TEL) for a position at the current block's `sqrtPriceX96`
     * @dev Because voting weight is TEL-denominated, it fluctuates with price changes & impermanent loss
     * Uses TEL denomination rather than liquidity units for backwards compatibility w/ Snapshot's 
     * `erc20-balance-of-with-delegation` schema & preexisting integrations like VotingWeightCalculator
     * @param tokenId The position identifier
     */
    function computeVotingWeight(uint256 tokenId) external view returns (uint256) {
        //todo MUST REQUIRE SUBSCRIBED, which excludes transferred positions (which are unsubscribed)

        uint128 liquidity = _getLiquidityLast(tokenId);
        if (liquidity == 0) return 0;

        Position storage pos = positions[tokenId];
        PoolId poolId = pos.poolId;
        (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) = getAmountsForLiquidity(poolId, liquidity, pos.tickLower, pos.tickUpper);

        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 2 ** 96);

        // todo: refactor to currency0 and currency1, incorporating price quote/calculation for stablecoin (nonTEL) pools
        PoolKey memory key = initializedPoolKeys[poolId];
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

    //todo: delete extraneous interfaces in external

    /**
     * @notice Computes currency0 & currency1 amounts for given liquidity at current tick price
     * @dev Exposes Uniswap V3/V4 concentrated liquidity math publicly for TELx frontend use
     */
    function getAmountsForLiquidity(
        PoolId poolId,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    ) public view returns (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = stateView.getSlot0(poolId);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, 
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );

        return (amount0, amount1, sqrtPriceX96);
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
    function updateRouter(address router, bool listed) external onlyRole(SUPPORT_ROLE) {
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
        onlyRole(UNI_HOOK_ROLE) //todo this role thing is awkward, point at const?
    {
        // Does not fail on invalid poolId, just skips update
        if (!validPool(poolId)) {
            return;
        }

        require(liquidityDelta != type(int128).min, "PositionRegistry: Invalid liquidity delta"); //todo: remove assertion

        Position storage pos = positions[tokenId];

        bool isNew;
        address tokenOwner;
        uint128 newLiquidity;
        if (pos.owner == UNTRACKED) {
            return;
        } else if (pos.owner == address(0)) {
            // new position
            isNew = true;
            require(liquidityDelta >= 0, "NEGATIVE LIQ NEW POSITION"); //todo: remove assertion
            newLiquidity = uint128(liquidityDelta);

            try positionManager.ownerOf(tokenId) returns (address lp) {
                tokenOwner = lp;
            } catch {
                // the position was not created via PositionManager
                _setUntracked(tokenId);
                return;
            }
        } else {
            // known position
            if (liquidityDelta > 0) {
                newLiquidity = _getLiquidityLast(tokenId) + uint128(liquidityDelta);
            } else {
                // the case where `liquidityDelta == 0` is permitted for fee collection
                uint128 delta = uint128(-liquidityDelta);
                require(_getLiquidityLast(tokenId) >= delta, "PositionRegistry: Insufficient liquidity"); //todo: remove assertion
                newLiquidity = _getLiquidityLast(tokenId) - delta;
            }

            try positionManager.ownerOf(tokenId) returns (address lp) {
                tokenOwner = lp;
            } catch {
                // token is being burned and if subscribed will be unsubscribed
                _setUntracked(tokenId);
                _addCheckpoint(tokenId, uint32(block.number), newLiquidity);
                return;
            }
        }

        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        
        require(PoolId.unwrap(poolKey.toId()) == PoolId.unwrap(poolId), "PositionRegistry: PoolId mismatch"); //todo: remove assertion
        if (!isNew) { //todo: remove assertion
            require(pos.tickLower == info.tickLower(), "PositionRegistry: tickLower mismatch"); //todo: remove assertion
            require(pos.tickUpper == info.tickUpper(), "PositionRegistry: tickUpper mismatch"); //todo: remove assertion
        }
        
        // record in positions mapping and checkpoints list, await LP opt-in via `subscribe`
        _updatePosition(tokenId, tokenOwner, poolId, info.tickLower(), info.tickUpper(), newLiquidity, isNew);
        _addCheckpoint(tokenId, uint32(block.number), newLiquidity);

        // todo: internal fn to identify fees being collected and store it? or do offchain
        // if so fn must also be used during addRewards()

        //todo: must ENSURE ownerPositions ALWAYS IN SYNC
        if (ownerPositions[tokenOwner].length <= MAX_POSITIONS) {
            ownerPositions[tokenOwner].push(tokenId);
        }
    }

    /// @dev Return the last recorded liquidity for a position
    function _getLiquidityLast(uint256 tokenId) internal view returns (uint128) {
        Position storage pos = positions[tokenId];
        uint256 len = pos.liquidityModifications.length();
        if (len == 0) return 0;

        return SafeCast.toUint128(pos.liquidityModifications.latest());
    }

    /// @dev Mark a position as untracked because it was burned or not created via PositionManager
    function _setUntracked(uint256 tokenId) internal {
        positions[tokenId].owner = UNTRACKED;
    }

    function _updatePosition(uint256 tokenId, address newOwner, PoolId poolId, int24 tickLower, int24 tickUpper, uint128 newLiquidity, bool isNew) internal {
        if (isNew) {
            require(positions[tokenId].owner == address(0x0), "PositionRegistry: Position already exists"); //todo: remove assertion
            require(positions[tokenId].liquidityModifications.length() == 0, "PositionRegistry: Position already exists"); //todo: remove assertion
            require(positions[tokenId].tickLower == 0, "PositionRegistry: Position already exists"); //todo: remove assertion
            require(positions[tokenId].tickUpper == 0, "PositionRegistry: Position already exists"); //todo: remove assertion

            positions[tokenId].owner = newOwner;
            positions[tokenId].poolId = poolId;
            positions[tokenId].tickLower = tickLower;
            positions[tokenId].tickUpper = tickUpper;
        } else {
            //todo: maybe optimization: if position is known + subscribed AND liquidity is lowered to zero, "unsubscribe" it from this contract's perspective
            
            require(positions[tokenId].owner != address(0x0), "PositionRegistry: Position already exists"); //todo: remove assertion
            require(positions[tokenId].liquidityModifications.length() != 0, "PositionRegistry: Position already exists"); //todo: remove assertion
            require(positions[tokenId].tickLower != 0, "PositionRegistry: Position already exists"); //todo: remove assertion
            require(positions[tokenId].tickUpper != 0, "PositionRegistry: Position already exists"); //todo: remove assertion

            positions[tokenId].owner = newOwner;
            positions[tokenId].poolId = poolId;
        }

        emit PositionUpdated(tokenId, newOwner, poolId, tickLower, tickUpper, uint128(newLiquidity));
    }

    function _addCheckpoint(uint256 tokenId, uint32 checkpointBlock, uint128 newLiquidity) internal {
        Position storage pos = positions[tokenId];
        pos.liquidityModifications.push(checkpointBlock, newLiquidity);

        // tick initialization occurs immediately before adding liquidity, so fee growth can be read safely before addition
        // tick deinitialization occurs after removing liquidity, so fee growth can be read safely before removal
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = stateView.getFeeGrowthInside(
            pos.poolId,
            pos.tickLower,
            pos.tickUpper
        );
        pos.feeGrowthCheckpoints[checkpointBlock] = FeeGrowthCheckpoint({
            feeGrowthInside0X128: SafeCast.toUint128(feeGrowthInside0X128),
            feeGrowthInside1X128: SafeCast.toUint128(feeGrowthInside1X128)
        });

        // update metadata for better searchability offchain
        CheckpointMetadata storage metadata = positionMetadata[tokenId];
        if (metadata.firstCheckpoint == 0) {
            metadata.firstCheckpoint = checkpointBlock;
        }
        metadata.lastCheckpoint = checkpointBlock;
        uint256 checkpointIndex = metadata.totalCheckpoints++;

        emit Checkpoint(tokenId, checkpointIndex, feeGrowthInside0X128, feeGrowthInside1X128);
    }

    /**
     * @notice Internally removes a position from both the owner and global registries.
     * @param tokenId The identifier of the position to remove.
     * @param owner The address of the LP whose position is now subscribed.
     */
    function _removeSubscribedPosition(uint256 tokenId, address owner) internal {
        uint256[] storage list = subscribedTokenIds[owner]; //todo: this also needs to remove from subscriptions array
        for (uint256 j = 0; j < list.length; j++) {
            if (list[j] == tokenId) {
                list[j] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    /**
     * @notice Removes a position from the owner registries.
     * @dev Emits a PositionRemoved event.
     * @param tokenId The identifier of the position to remove.
     * @param owner The address of the LP whose position is being removed.
     * @param poolId The pool associated with the position.
     * @param tickLower The lower tick boundary of the position.
     * @param tickUpper The upper tick boundary of the position.
     */
    function _removeOwnerPosition(uint256 tokenId, address owner, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
    {
        uint256[] storage list = ownerPositions[owner];
        for (uint256 j = 0; j < list.length; j++) {
            if (list[j] == tokenId) {
                list[j] = list[list.length - 1];
                list.pop();
                break;
            }
        }

        emit PositionRemoved(tokenId, owner, poolId, tickLower, tickUpper); //todo: do we even want this?
    }

    /**
     * @notice Registers a position's ownership using the NFT tokenId.
     * @dev Must be invoked during hooks by an address with SUBSCRIBER_ROLE, such as TELxSubscriber
     *      Reads the existing position metadata, and updates LP position ownership if necessary
     * @dev LPs must call `PositionManager::subscribe()` to graduate unsubscribed (new) positions to active tracking
     * @param tokenId The NFT tokenId corresponding to the original position.
     */
    function handleSubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        Position storage pos = positions[tokenId];
        require(pos.owner != UNTRACKED, "PositionRegistry: Only positions created via PositionManager can be subscribed");

        // todo: approved can also call this not just owner; are there conditions where reverting here causes problem
        address newOwner = IPositionManager(positionManager).ownerOf(tokenId);

        (PoolKey memory poolKey, /*PositionInfo info*/) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();

        // Skip if not a known TEL pool
        if (!validPool(poolId)) {
            return;
        }

        // if ( todo: max subscribed positions handling
        //     subscribedTokenIds[tokenOwner].length <= MAX_POSITIONS
        // ) {
        //     subscribedTokenIds[tokenOwner].push(tokenId);
        // }
        // return;

        //todo implement isSubscribed(), simply search subscribedTokenIds[newOwner] for tokenId?
        // if (isSubscribed(tokenId)) {
        //     // no-op resubscriptions
        //     //todo: is it even possible to resubscribe?
        //     return;
        // }

        if (pos.owner == address(0x0)) {
            //todo: should be impossible since positions will already be recorded
            revert("PositionRegistry: Subscribing unknown position");
        } else {
            // new subscription; update state and emit event for offchain availability
            subscriptions.push(tokenId);

            emit Subscribed(tokenId, newOwner);
        }

        //todo: should we also track all an owner's *SUBSCRIBED* positions? maybe this should replace ownerPositions
    }

    /**
     * @notice Deregisters a position.
     * @dev Must be invoked during hooks by an address with SUBSCRIBER_ROLE, such as TELxSubscriber
     *      Invoked during v4 unsubscription hooks during LP token transfers 
     *      Reads the existing position metadata, removes it from the old owner, and reassigns it to the new owner.
     * @param tokenId The NFT tokenId corresponding to the original position.
     */
    function handleUnsubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        require(tokenId != 0, "PositionRegistry: Invalid tokenId");
        address newOwner = IPositionManager(positionManager).ownerOf(tokenId); //todo: can this fail?

        (PoolKey memory poolKey, /*PositionInfo info*/) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();

        // Skip if not a known initialized TEL pool
        if (!validPool(poolId)) {
            return;
        }

        Position storage pos = positions[tokenId];

        _removeSubscribedPosition(tokenId, pos.owner);

        // no change in ownership implicates self transfer or a direct call to unsubscribe()
        if (pos.owner == newOwner) {
            return;
        } else {
            _removeOwnerPosition(tokenId, pos.owner, poolId, pos.tickLower, pos.tickUpper);
        }
    }

    //todo: _handleBurn should update position
    //todo: should it also add final checkpoint? probably already handled by beforeRemoveLiquidity
    function handleBurn(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {}


    /**
     * @notice Adds batch rewards for many users in a specific block round
     * @param lps LP addresses
     * @param amounts Reward values per address
     * @param totalAmount Sum of all `amounts`
     */
    function addRewards(address[] calldata lps, uint256[] calldata amounts, uint256 totalAmount)
        external
        nonReentrant
        onlyRole(SUPPORT_ROLE)
    {
        require(lps.length == amounts.length, "PositionRegistry: Length mismatch");

        telcoin.safeTransferFrom(_msgSender(), address(this), totalAmount);

        uint256 total = 0;
        for (uint256 i = 0; i < lps.length; i++) {
            // _addCheckpoint(tokenId, uint32(block.number), newLiquidity); //todo: align all subscribed positions at period end

            unclaimedRewards[lps[i]] += amounts[i];
            total += amounts[i];

            emit RewardsAdded(lps[i], amounts[i]);
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
