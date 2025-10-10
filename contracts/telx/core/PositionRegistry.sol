// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPositionRegistry, PoolId} from "../interfaces/IPositionRegistry.sol";
import {IMsgSender} from "../interfaces/IMsgSender.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionManager, PoolKey, PositionInfo} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// this contract stores fee tracking information (tokenId => fees), written at modifyLiquidity and addRewards time 
// the goal is to be able to reconstruct fee growth inside at any point in time for subscribed positions
//todo: what is the best way to implement data storage so that getFeeGrowth(startBlock, endBlock) can be efficiently queried offchain?
//   - checkpointing
// offchain script can then pull fee tracking info and calculate final checkpoint subperiod
// during addRewards, maybe final checkpoint should be written to align all subscribed positions checkpoints at period endBlock?
// todo: update spec.md -> README.md and incorporate google doc to current markdown

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

    uint256 constant MAX_SUBSCRIPTIONS = 100; //todo: this can be increased due to refactor efficiency
    uint256 constant MAX_SUBSCRIBED = 100; //todo: this can be increased due to refactor efficiency
    /// @dev Marks positions either burned or not created via PositionManager
    address constant UNTRACKED = address(type(uint160).max);

    mapping(address => bool) public routers;
    mapping(PoolId => PoolKey) public initializedPoolKeys;
    
    /// @notice Mapping to track all positions associated with supported pools
    mapping(uint256 => Position) public positions;
    mapping(uint256 => CheckpointMetadata) public positionMetadata;
    
    /// @notice The current set of active subscriptions participating in the TELxIncentives program
    address[] public subscribed;
    mapping(address => uint256[]) public subscriptions;

    mapping(address => uint256) public unclaimedRewards;
    
    //todo: view function to fetch liquidityModifications
    
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

    /// @inheritdoc IPositionRegistry
    function validPool(PoolId id) public view override returns (bool) {
        address currency0 = Currency.unwrap(initializedPoolKeys[id].currency0);
        address currency1 = Currency.unwrap(initializedPoolKeys[id].currency1);
        if (currency0 != address(0x0) || currency1 != address(0x0)) {
            return true;
        }

        return false;
    }

    /// @inheritdoc IPositionRegistry
    function getPosition(uint256 tokenId) external view returns (
        address owner,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) {
        Position storage pos = positions[tokenId];
        return (pos.owner, pos.poolId, pos.tickLower, pos.tickUpper);
    }

    /// @inheritdoc IPositionRegistry
    function getLiquidityLast(uint256 tokenId) external view returns (uint128) {
        return _getLiquidityLast(tokenId);
    }

    function _getLiquidityLast(uint256 tokenId) internal view returns (uint128) {
        Position storage pos = positions[tokenId];
        uint256 len = pos.liquidityModifications.length();
        if (len == 0) return 0;

        return SafeCast.toUint128(pos.liquidityModifications.latest());
    }

    /// @inheritdoc IPositionRegistry
    function getSubscriptions(address owner) external view override returns (uint256[] memory) {
        return subscriptions[owner];
    }

    /// @inheritdoc IPositionRegistry
    function getSubscribed() external view returns (address[] memory) {
        return subscribed;
    }

    /// @inheritdoc IPositionRegistry
    function computeVotingWeight(uint256 tokenId) external view returns (uint256) {
        if (!isSubscribed(tokenId)) return 0;

        uint128 liquidity = _getLiquidityLast(tokenId);
        if (liquidity == 0) return 0;

        Position storage pos = positions[tokenId];
        PoolId poolId = pos.poolId;
        (uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) = getAmountsForLiquidity(poolId, liquidity, pos.tickLower, pos.tickUpper);

        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 2 ** 96);

        PoolKey memory key = initializedPoolKeys[poolId];
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        uint8 telIndex = currency0 == address(telcoin) ? 0 : currency1 == address(telcoin) ? 1 : 2;
        if (telIndex == 2) {
            //todo this is a nonTEL pool; we need to get some kind of price of both currency0 and currency1 in TEL
            // todo: incorporate price quote/calculation for stablecoin (nonTEL) pools using current price? VWAP? oracle?
        }

        if (telIndex == 0) {
            return amount0 + FullMath.mulDiv(amount1, 2 ** 96, priceX96);
        } else if (telIndex == 1) {
            return amount1 + FullMath.mulDiv(amount0, priceX96, 2 ** 96);
        }

        return 0;
    }

    /// @inheritdoc IPositionRegistry
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

    /// @inheritdoc IPositionRegistry
    function addOrUpdatePosition(uint256 tokenId, PoolId poolId, int128 liquidityDelta)
        external
        onlyRole(UNI_HOOK_ROLE)
    {
        // Does not fail on invalid poolId, just skips update
        if (!validPool(poolId)) {
            return;
        }

        require(liquidityDelta > type(int128).min, "PositionRegistry: Invalid liquidity delta"); //todo: remove assertion

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

            try IERC721(address(positionManager)).ownerOf(tokenId) returns (address lp) {
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

            try IERC721(address(positionManager)).ownerOf(tokenId) returns (address lp) {
                tokenOwner = lp;
            } catch {
                // token is being burned; if subscribed retain ownership for subsequent untracking
                if (!isSubscribed(tokenId)) _setUntracked(tokenId);
                _writeCheckpoint(tokenId, uint32(block.number), newLiquidity);
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
        _writeCheckpoint(tokenId, uint32(block.number), newLiquidity);
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

            positions[tokenId].owner = newOwner;
            positions[tokenId].poolId = poolId;
        }

        emit PositionUpdated(tokenId, newOwner, poolId, tickLower, tickUpper, uint128(newLiquidity));
    }

    function _writeCheckpoint(uint256 tokenId, uint32 checkpointBlock, uint128 newLiquidity) internal {
        Position storage pos = positions[tokenId];
        PoolId poolId = pos.poolId;
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

        emit Checkpoint(tokenId, poolId, checkpointIndex, feeGrowthInside0X128, feeGrowthInside1X128);
    }

    /// @dev Mark a position as untracked because it was burned or not created via PositionManager
    function _setUntracked(uint256 tokenId) internal {
        positions[tokenId].owner = UNTRACKED;
    }

    /**
     * Subscriptions
     */

    /// @inheritdoc IPositionRegistry
    function isSubscribed(uint256 tokenId) public view returns (bool) {
        Position storage pos = positions[tokenId];
        if (pos.owner == address(0x0) || pos.owner == UNTRACKED) return false;

        uint256[] storage subscribedIds = subscriptions[pos.owner];
        uint256 len = subscribedIds.length;
        for (uint256 i; i < len; ++i) {
            if (subscribedIds[i] == tokenId) {
                return true;
            }
        }

        return false;
    }

    /// @inheritdoc IPositionRegistry
    function handleSubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        Position storage pos = positions[tokenId];
        require(validPool(pos.poolId), "PositionRegistry: Invalid pool");
        require(pos.owner != UNTRACKED, "PositionRegistry: Only positions created via PositionManager can be subscribed");

        // approved may also initiate subscribe flow but the token owner is counted for subscription anyway
        address tokenOwner = IERC721(address(positionManager)).ownerOf(tokenId);
        require(subscriptions[tokenOwner].length <= MAX_SUBSCRIPTIONS && subscribed.length <= MAX_SUBSCRIBED, "PositionRegistry: Exceeds max subscriptions");
        // `pos.owner` may be stale since ownership ledger is only updated during liquidity modifications
        if (pos.owner != tokenOwner) _updatePosition(tokenId, tokenOwner, pos.poolId, pos.tickLower, pos.tickUpper, _getLiquidityLast(tokenId), false);

        bool isDuplicate;
        for (uint256 i; i < subscribed.length; ++i) {
            if (subscribed[i] == tokenOwner) {
                isDuplicate = true;
                break;
            }
        }

        if (!isDuplicate) subscribed.push(tokenOwner);
        subscriptions[tokenOwner].push(tokenId);

        emit Subscribed(tokenId, tokenOwner);
    }

    /// @inheritdoc IPositionRegistry
    function handleUnsubscribe(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        Position storage pos = positions[tokenId];
        _removeSubscription(tokenId, pos.owner);
    }

    /// @inheritdoc IPositionRegistry
    /// @dev Identifies fees being collected and stores a fee-specific checkpoint so the fee tracking must be easily consumable offchain
    /// @notice Only subscribed positions are eligible for rewards
    function handleModifyLiquidity(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        // todo: internal fn to identify fees being collected and store it? or do offchain
        // if so fn must also be used during addRewards()


        //todo move natspec to interface
    }

    /// @inheritdoc IPositionRegistry
    function handleBurn(uint256 tokenId) external onlyRole(SUBSCRIBER_ROLE) {
        Position storage pos = positions[tokenId];
        // ownership information is retained during `beforeRemoveLiquidity` hook in burn contexts
        _removeSubscription(tokenId, pos.owner);
        _setUntracked(tokenId);
    }

    /**
     * @notice Delete `tokenId` from `subscriptions` map as well as `subscribed` array if appropriate
     * @param tokenId The identifier of the position to remove.
     * @param owner The address of the LP whose position is being removed.
     */
    function _removeSubscription(uint256 tokenId, address owner)
        internal
    {
        uint256[] storage list = subscriptions[owner];
        uint256 len = list.length;
        for (uint256 i; i < len; ++i) {
            if (list[i] == tokenId) {
                list[i] = list[len - 1];
                list.pop();
                break;
            }
        }

        if (len == 1) {
            // owner has no more subscriptions, remove from subscribed array
            uint256 subscribedLen = subscribed.length;
            for (uint256 i; i < subscribedLen; i++) {
                if (subscribed[i] == owner) {
                    subscribed[i] = subscribed[subscribedLen - 1];
                    subscribed.pop();
                    break;
                }
            }
        }

        emit Unsubscribed(tokenId, owner);
    }

    /**
     * Rewards
     */

    /// @inheritdoc IPositionRegistry
    function addRewards(address[] calldata lps, uint256[] calldata amounts, uint256 totalAmount)
        external
        nonReentrant
        onlyRole(SUPPORT_ROLE)
    {
        require(lps.length == amounts.length, "PositionRegistry: Length mismatch");

        telcoin.safeTransferFrom(_msgSender(), address(this), totalAmount);

        uint256 total = 0;
        for (uint256 i = 0; i < lps.length; i++) {
            // _writeCheckpoint(tokenId, uint32(block.number), newLiquidity); //todo: align all subscribed positions at period end

            unclaimedRewards[lps[i]] += amounts[i];
            total += amounts[i];
        }

        require(total == totalAmount, "PositionRegistry: Total amount mismatch");
    }

    /// @inheritdoc IPositionRegistry
    function claim() external nonReentrant {
        uint256 reward = unclaimedRewards[_msgSender()];
        require(reward > 0, "PositionRegistry: No claimable rewards");

        unclaimedRewards[_msgSender()] = 0;
        telcoin.safeTransfer(_msgSender(), reward);

        emit RewardsClaimed(_msgSender(), reward);
    }

    /// @inheritdoc IPositionRegistry
    function getUnclaimedRewards(address user) external view returns (uint256) {
        return unclaimedRewards[user];
    }

    /**
     * Administration
     */

    /// @inheritdoc IPositionRegistry
    function initialize(address sender, PoolKey calldata key) external onlyRole(UNI_HOOK_ROLE) {
        require(hasRole(DEFAULT_ADMIN_ROLE, _resolveUser(sender)), "PositionRegistry: Only admin can initialize pools with this hook");
        require(!validPool(key.toId()), "PositionRegistry: Pool already initialized");
        initializedPoolKeys[key.toId()] = key;

        emit PoolInitialized(key);
    }

    /// @inheritdoc IPositionRegistry
    function updateRouter(address router, bool listed) external onlyRole(SUPPORT_ROLE) {
        routers[router] = listed;

        emit RouterRegistryUpdated(router, listed);
    }

    /// @inheritdoc IPositionRegistry
    function isActiveRouter(address router) public view override returns (bool) {
        return routers[router];
    }

    /// @inheritdoc IPositionRegistry
    function erc20Rescue(IERC20 token, address destination, uint256 amount) external onlyRole(SUPPORT_ROLE) {
        token.safeTransfer(destination, amount);
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
}
