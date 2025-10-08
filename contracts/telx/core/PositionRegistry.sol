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
    /// @dev Marks positions either burned or not created via PositionManager
    address constant UNTRACKED = address(type(uint160).max);

    mapping(address => uint256[]) public ownerTokenIds; //todo delete
    mapping(address => uint256[]) public unsubscribedTokenIds;
    mapping(address => uint256) public unclaimedRewards;
    mapping(PoolId => PoolKey) public initializedPoolKeys;
    mapping(address => bool) public routers;

    //todo: refactored state
    /// @notice Mapping to track all positions associated with supported pools
    mapping(uint256 => Position) public positions;
    /// @notice The current set of active positions participating in TELxIncentives program via subscription
    uint256[] public subscriptions;
    /// @notice History of positions' fee information: `tokenId => {block, telDenominatedFees}`
    /// @dev Since Trace224 array is unbounded it can grow beyond EVM memory limits
    /// do not load into EVM memory; consume offchain instead and fall back to loading slots if needed
    mapping(uint256 => Checkpoints.Trace224) private feeRecords;
    //todo: view function to fetch feeRecords
    /// @notice Maps period numbers to their end block
    mapping(uint256 => uint32) public periodEndBlock;
    uint256 currentPeriod;

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
     * @notice Returns tokenIds for an owner that have been subscribed
     */
    function getSubscribedTokenIdsByOwner(address owner) external view override returns (uint256[] memory) {
        return ownerTokenIds[owner]; //todo function to loop through subscribedTokenIds and filter by owner address
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
        if (pos.owner != IPositionManager(positionManager).ownerOf(tokenId)) {
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
            try positionManager.ownerOf(tokenId) returns (address lp) {
                tokenOwner = lp;
            } catch {
                // the position was not created via PositionManager
                _setUntracked(tokenId);
                return;
            }

            require(liquidityDelta >= 0, "NEGATIVE LIQ NEW POSITION"); //todo: remove assertion
            newLiquidity = uint128(liquidityDelta);
        } else {
            // known position
            try positionManager.ownerOf(tokenId) returns (address lp) {
                tokenOwner = lp;
            } catch {
                // token is being burned and if subscribed will be unsubscribed
                _setUntracked(tokenId);
                // _addCheckpoint(); //todo
                return;
            }

            if (liquidityDelta > 0) {
                newLiquidity = pos.liquidity + uint128(liquidityDelta);
            } else {
                // the case where `liquidityDelta == 0` is permitted for fee collection
                uint128 delta = uint128(-liquidityDelta);
                require(pos.liquidity >= delta, "PositionRegistry: Insufficient liquidity"); //todo: remove assertion
                newLiquidity = pos.liquidity - delta;
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
        //todo: this function should write a fee tracking checkpoint (modifyLiquidity time)
        // _addCheckPoint();

        // todo: internal fn to identify fees being collected and store it; fn must also be used during addRewards()
    }

    function _setUntracked(uint256 tokenId) internal {
        positions[tokenId].owner = UNTRACKED;
    }

    function _updatePosition(uint256 tokenId, address newOwner, PoolId poolId, int24 tickLower, int24 tickUpper, uint128 newLiquidity, bool isNew) internal {
        if (isNew) {
            positions[tokenId] = Position({
                owner: newOwner,
                poolId: poolId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: newLiquidity
            });
        } else {
            //todo: maybe optimization: if position is known + subscribed AND liquidity is lowered to zero, "unsubscribe" it from this contract's perspective
            positions[tokenId].owner = newOwner;
            positions[tokenId].liquidity = newLiquidity;
        }

        emit PositionUpdated(tokenId, newOwner, poolId, tickLower, tickUpper, uint128(newLiquidity));
    }

    /**
     * @notice Internally removes a position from both the owner and global registries.
     * @param tokenId The identifier of the position to remove.
     * @param owner The address of the LP whose position is now subscribed.
     */
    function _removeUnsubscribedPosition(uint256 tokenId, address owner) internal {
        uint256[] storage list = unsubscribedTokenIds[owner];
        for (uint256 j = 0; j < list.length; j++) {
            if (list[j] == tokenId) {
                list[j] = list[list.length - 1];
                list.pop();
                break;
            }
        }
    }

    /**
     * @notice Internally removes a position from both the owner and global registries.
     * @dev Deletes the position mapping, removes from ownerPositions arrays.
     *      Emits a PositionRemoved event.
     * @param tokenId The identifier of the position to remove.
     * @param owner The address of the LP whose position is being removed.
     * @param poolId The pool associated with the position.
     * @param tickLower The lower tick boundary of the position.
     * @param tickUpper The upper tick boundary of the position.
     */
    function _removePosition(uint256 tokenId, address owner, PoolId poolId, int24 tickLower, int24 tickUpper)
        internal
    {
        delete positions[tokenId];

        uint256[] storage list = ownerTokenIds[owner];
        for (uint256 j = 0; j < list.length; j++) {
            if (list[j] == tokenId) {
                list[j] = list[list.length - 1];
                list.pop();
                break;
            }
        }

        emit PositionRemoved(tokenId, owner, poolId, tickLower, tickUpper);
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

        // Skip if not a known TEL pool
        if (!validPool(poolId)) {
            return;
        }

        Position storage pos = positions[tokenId];
        // if ( todo: max positions handling
        //     subscribedTokenIds[tokenOwner].length <= MAX_POSITIONS
        // ) {
        //     subscribedTokenIds[tokenOwner].push(tokenId);
        // }
        // return;

        // No change in ownership
        // Liquidity should be updated via addOrUpdatePosition actions anyway due to the hook.
        if (pos.owner == newOwner) {
            //todo: this represents case where subscribe is called again on an already subscribed position
            // if handleUnsubscribe updates transferred positions, `pos.owner == newOwner` is unnecessary
            // and can be changed to `pos.owner != address(0)` to no-op re-subscriptions
            return;
        }

        if (pos.owner == address(0)) {
            // new position; emit the event for offchain availability & remove from unsubscribed state
            _removeUnsubscribedPosition(tokenId, newOwner);
            emit Subscribed(tokenId, newOwner);
        } else { //todo: logic in this branch should be handled by handleUnsubscribe() bc it represents ownership transfer
            // known position (subscribed) ownership change; remove the position from the old LP
            _removePosition(tokenId, pos.owner, poolId, pos.tickLower, pos.tickUpper);
        }

        // add position state to new owner's tracked state
        uint128 liquidity = IPositionManager(positionManager).getPositionLiquidity(tokenId);
        positions[tokenId] = Position({
            owner: newOwner,
            poolId: poolId,
            tickLower: info.tickLower(),
            tickUpper: info.tickUpper(),
            liquidity: liquidity
        });

        if (ownerTokenIds[newOwner].length <= MAX_POSITIONS) {
            ownerTokenIds[newOwner].push(tokenId);
            emit PositionUpdated(tokenId, newOwner, poolId, info.tickLower(), info.tickUpper(), liquidity);
        }
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
        address newOwner = IPositionManager(positionManager).ownerOf(tokenId);

        (PoolKey memory poolKey, PositionInfo info) = IPositionManager(positionManager).getPoolAndPositionInfo(tokenId);
        PoolId poolId = poolKey.toId();

        // Skip if not a known TEL pool registered by `SUPPORT_ROLE`
        if (!validPool(poolId)) {
            return;
        }

        Position storage pos = positions[tokenId];

        // no change in ownership implies this is a self transfer or a direct call to unsubscribe()
        if (pos.owner == newOwner) {
            return;
        }
    }

    //todo: _handleBurn should update position and add final checkpoint
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
