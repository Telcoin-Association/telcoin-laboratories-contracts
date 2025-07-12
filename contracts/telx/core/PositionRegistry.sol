// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPositionRegistry, PoolId} from "../interfaces/IPositionRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager, PoolKey, PositionInfo} from "../interfaces/IPositionManager.sol";

/**
 * @title Position Registry
 * @author Amir M. Shirif
 * @notice Tracks Uniswap V4 LP positions and manages off-chain reward distribution.
 * @dev This contract is designed to work with a Uniswap V4 hook to emit on-chain events, which are processed by an off-chain reward calculation system.
 */
contract PositionRegistry is IPositionRegistry, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a position is added or its liquidity is increased
    event PositionUpdated(
        uint256 indexed tokenId,
        address indexed provider,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// @notice Emitted when a position's liquidity reaches zero and is removed
    event PositionRemoved(
        uint256 indexed tokenId,
        address indexed provider,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper
    );

    /// @notice Emitted when reward tokens are added to a user
    event RewardsAdded(address indexed provider, uint256 amount);

    /// @notice Emitted when a user successfully claims their reward
    event RewardsClaimed(address indexed provider, uint256 amount);

    /// @notice Emitted when a new reward distribution round is initialized
    event UpdateBlockStamp(uint256 rewardBlock, uint256 totalRewardAmount);

    /// @notice Emitted when a router's trust status is updated.
    event RouterRegistryUpdated(address indexed router, bool listed);

    /// @notice Emitted when the TEL token position is updated for a pool.
    event TelPositionUpdated(PoolId indexed poolId, uint8 location);

    /// @notice Emitted when a token is subscribed for the first time
    event Subscribed(uint256 indexed tokenId, address indexed owner);

    bytes32 public constant UNI_HOOK_ROLE = keccak256("UNI_HOOK_ROLE");
    bytes32 public constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");
    bytes32 public constant SUBSCRIBER_ROLE = keccak256("SUBSCRIBER_ROLE");

    uint256 constant MAX_POSITIONS = 100;

    mapping(address => uint256) public unclaimedRewards;
    mapping(PoolId => uint8) public telcoinPosition;
    mapping(address => bool) public routers;
    mapping(uint256 => bool) public hasSubscribed;
    mapping(uint256 => address) internal tokenIdToOwner;
    mapping(address => uint256[]) internal providerTokenIds;
    mapping(uint256 => Position) public positions;

    IERC20 public immutable telcoin;
    uint256 public lastRewardBlock;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    /**
     * @notice Initializes the registry with a reward token
     * @param _telcoin The ERC20 token used to pay LP rewards
     */
    constructor(
        IERC20 _telcoin,
        IPoolManager _poolManager,
        IPositionManager _positionManager
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        telcoin = _telcoin;
        poolManager = _poolManager;
        positionManager = _positionManager;
        lastRewardBlock = block.number;
    }

    /**
     * @notice Returns whether a given PoolId is associated with a TEL position.
     * @dev A PoolId is considered valid if a TEL token exists at index 1 or 2.
     * @param id The unique identifier for the Uniswap V4 pool.
     * @return True if the pool has a non-zero TEL token position mapping.
     */
    function validPool(PoolId id) external view override returns (bool) {
        return telcoinPosition[id] != 0;
    }

    /**
     * @notice Returns whether a router is in the trusted routers list.
     * @dev Used to determine if a router can be queried for the actual msg.sender.
     * @param router The address of the router to query.
     * @return True if the router is listed as trusted.
     */
    function activeRouters(
        address router
    ) external view override returns (bool) {
        return routers[router];
    }

    /**
     * @notice Returns position metadata given its ID
     */
    function getPosition(
        uint256 tokenId
    ) external view returns (Position memory) {
        return positions[tokenId];
    }

    /**
     * @notice Gets list of user positions
     */
    function getPositionsByStaker(
        address staker
    ) external view returns (uint256[] memory) {
        return providerTokenIds[staker];
    }

    /**
     * @notice Gets unclaimed reward balance for a user
     */
    function getUnclaimedRewards(address user) external view returns (uint256) {
        return unclaimedRewards[user];
    }

    /**
     * @notice Returns the voting weight (in TEL) for a position at a given sqrtPriceX96
     * @dev Assumes TEL is always token0 for simplicity — adjust logic if needed
     * @param tokenId The position identifier
     */
    function computeVotingWeight(
        uint256 tokenId
    ) external view returns (uint256) {
        Position storage pos = positions[tokenId];
        if (pos.liquidity == 0 || !hasSubscribed[tokenId]) return 0;

        address trackedOwner = tokenIdToOwner[tokenId];
        address actualOwner = IPositionManager(positionManager).ownerOf(
            tokenId
        );
        if (trackedOwner != actualOwner) return 0;

        PoolId poolId = pos.poolId;
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(
            poolManager,
            poolId
        );

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper),
            pos.liquidity
        );

        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 2 ** 96);
        uint8 index = telcoinPosition[poolId];

        if (index == 1) {
            return amount0 + FullMath.mulDiv(amount1, 2 ** 96, priceX96);
        } else if (index == 2) {
            return amount1 + FullMath.mulDiv(amount0, priceX96, 2 ** 96);
        }

        return 0;
    }

    /**
     * @notice Computes the amounts of token0 and token1 for given liquidity and prices
     * @dev Used for Uniswap V3/V4 style liquidity math
     */
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96)
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            uint256 intermediate = FullMath.mulDiv(
                liquidity,
                sqrtPriceBX96 - sqrtPriceAX96,
                sqrtPriceBX96
            );
            amount0 = FullMath.mulDiv(intermediate, 1 << 96, sqrtPriceAX96);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint256 intermediate = FullMath.mulDiv(
                liquidity,
                sqrtPriceBX96 - sqrtPriceX96,
                sqrtPriceBX96
            );
            amount0 = FullMath.mulDiv(intermediate, 1 << 96, sqrtPriceX96);

            amount1 = FullMath.mulDiv(
                liquidity,
                sqrtPriceX96 - sqrtPriceAX96,
                FixedPoint96.Q96
            );
        } else {
            amount1 = FullMath.mulDiv(
                liquidity,
                sqrtPriceBX96 - sqrtPriceAX96,
                FixedPoint96.Q96
            );
        }
    }

    /**
     * @notice Adds or removes a router from the trusted routers registry.
     * @dev Only callable by an address with SUPPORT_ROLE.
     * @param router The router address to update.
     * @param listed Whether the router should be marked as trusted.
     */
    function updateRegistry(
        address router,
        bool listed
    ) external onlyRole(SUPPORT_ROLE) {
        routers[router] = listed;
        emit RouterRegistryUpdated(router, listed);
    }

    /**
     * @notice Updates the stored index of TEL in a specific Uniswap V4 pool.
     * @dev Only callable by an address with SUPPORT_ROLE.
     *      Index must be 1 (token0) or 2 (token1).
     * @param poolId The unique identifier for the pool.
     * @param location The token index for TEL.
     */
    function updateTelPosition(
        PoolId poolId,
        uint8 location
    ) external onlyRole(SUPPORT_ROLE) {
        require(
            location >= 0 && location <= 2,
            "PositionRegistry: Invalid location"
        );
        telcoinPosition[poolId] = location;
        emit TelPositionUpdated(poolId, location);
    }

    /**
     * @notice Called by Uniswap hook to add or remove tracked liquidity
     * @param provider LP address
     * @param poolId Target pool
     * @param tickLower Lower tick bound
     * @param tickUpper Upper tick bound
     * @param liquidityDelta Change in liquidity (positive = add, negative = remove)
     */
    function addOrUpdatePosition(
        uint256 tokenId,
        address provider,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) external onlyRole(UNI_HOOK_ROLE) {
        if (telcoinPosition[poolId] == 0) {
            return;
        }

        require(
            liquidityDelta != type(int128).min,
            "PositionRegistry: Invalid liquidity delta"
        );

        // Enforce sync check if tokenId is subscribed
        if (hasSubscribed[tokenId]) {
            address trackedOwner = tokenIdToOwner[tokenId];
            address actualOwner = IPositionManager(positionManager).ownerOf(
                tokenId
            );

            if (trackedOwner != actualOwner) {
                revert(
                    "PositionRegistry: Must call subscribe to sync ownership"
                );
            }
        }

        Position storage pos = positions[tokenId];

        if (liquidityDelta > 0) {
            if (pos.liquidity == 0) {
                _addNewPosition(
                    provider,
                    poolId,
                    tickLower,
                    tickUpper,
                    tokenId,
                    uint128(liquidityDelta)
                );
            }

            _updatePositionLiquidity(
                tokenId,
                provider,
                poolId,
                tickLower,
                tickUpper,
                pos.liquidity + uint128(liquidityDelta)
            );
        } else {
            uint128 delta = uint128(-liquidityDelta);
            pos.liquidity -= delta;

            if (pos.liquidity == 0) {
                _removePosition(provider, tokenId);
            } else {
                _updatePositionLiquidity(
                    tokenId,
                    provider,
                    poolId,
                    tickLower,
                    tickUpper,
                    pos.liquidity
                );
            }
        }
    }

    /**
     * @notice Internally registers a new LP position under a specific provider.
     * @dev This function assumes the positionId is already computed externally.
     *      Adds the positionId to both the provider's list and the global active set.
     *      Fails if the provider has reached the MAX_POSITIONS limit.
     * @param provider The address of the LP owner.
     * @param poolId The identifier of the Uniswap V4 pool.
     * @param tickLower The lower tick boundary of the position.
     * @param tickUpper The upper tick boundary of the position.
     * @param tokenId The precomputed unique identifier for the position.
     * @param liquidity The liquidity being added
     */
    function _addNewPosition(
        address provider,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenId,
        uint128 liquidity
    ) internal {
        require(
            providerTokenIds[provider].length < MAX_POSITIONS,
            "Too many positions"
        );

        Position storage pos = positions[tokenId];
        pos.provider = provider;
        pos.poolId = poolId;
        pos.tickLower = tickLower;
        pos.tickUpper = tickUpper;
        pos.liquidity = liquidity;

        providerTokenIds[provider].push(tokenId);

        emit PositionUpdated(
            tokenId,
            provider,
            poolId,
            tickLower,
            tickUpper,
            liquidity
        );
    }

    /**
     * @notice Updates the liquidity of an existing LP position and emits PositionUpdated.
     * @dev Assumes the position already exists in storage and has been properly added.
     * @param tokenId The identifier of the position to update.
     * @param provider The owner of the position (used for event emission).
     * @param poolId The Uniswap V4 pool associated with the position.
     * @param tickLower The lower tick boundary of the position.
     * @param tickUpper The upper tick boundary of the position.
     * @param newLiquidity The new liquidity value to assign.
     */
    function _updatePositionLiquidity(
        uint256 tokenId,
        address provider,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 newLiquidity
    ) internal {
        positions[tokenId].liquidity = newLiquidity;

        emit PositionUpdated(
            tokenId,
            provider,
            poolId,
            tickLower,
            tickUpper,
            newLiquidity
        );
    }

    /**
     * @notice Internally removes a position from both the provider and global registries.
     * @dev Deletes the position mapping, removes from providerPositions arrays.
     *      Emits a PositionRemoved event.
     * @param provider The address of the LP whose position is being removed.
     * @param tokenId The identifier of the position to remove.
     */
    function _removePosition(address provider, uint256 tokenId) internal {
        Position memory pos = positions[tokenId];

        delete positions[tokenId];

        uint256[] storage list = providerTokenIds[provider];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == tokenId) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }

        emit PositionRemoved(
            tokenId,
            provider,
            pos.poolId,
            pos.tickLower,
            pos.tickUpper
        );
    }

    /**
     * @notice Transfers a position's ownership to a new address using the NFT tokenId.
     * @dev Must be called by an address with the SUBSCRIBER_ROLE.
     *      Reads the existing position metadata, removes it from the old provider, and reassigns it to the new owner.
     *      Keeps liquidity unchanged and emits appropriate events.
     * @param tokenId The NFT tokenId corresponding to the original position.
     */
    function handleSubscribe(
        uint256 tokenId
    ) external onlyRole(SUBSCRIBER_ROLE) {
        address newOwner = IPositionManager(positionManager).ownerOf(tokenId);
        (PoolKey memory poolKey, PositionInfo info) = IPositionManager(
            positionManager
        ).getPoolAndPositionInfo(tokenId);
        PoolId poolId = PoolId.wrap(PoolId.unwrap(poolKey.toId()));

        if (telcoinPosition[poolId] == 0) {
            return;
        }

        int24 tickLower = info.tickLower();
        int24 tickUpper = info.tickUpper();
        uint128 liquidity = IPositionManager(positionManager)
            .getPositionLiquidity(tokenId);

        // First-time subscription
        if (!hasSubscribed[tokenId]) {
            tokenIdToOwner[tokenId] = newOwner;
            hasSubscribed[tokenId] = true;
            positions[tokenId] = Position({
                provider: newOwner,
                poolId: poolId,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: liquidity
            });
            providerTokenIds[newOwner].push(tokenId);
            emit Subscribed(tokenId, newOwner);
            return;
        }

        // It's a transfer — update tracked ownership
        address oldOwner = tokenIdToOwner[tokenId];
        if (oldOwner == newOwner) {
            return;
        }

        // Remove from old owner's registry
        _removePosition(oldOwner, tokenId);

        // Add to new owner's registry
        positions[tokenId] = Position({
            provider: newOwner,
            poolId: poolId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity
        });
        providerTokenIds[newOwner].push(tokenId);
        tokenIdToOwner[tokenId] = newOwner;
    }

    /**
     * @notice Adds batch rewards for many users in a specific block round
     * @param providers LP addresses
     * @param amounts Reward values per address
     * @param totalAmount Sum of all `amounts`
     * @param rewardBlock Block number associated with the reward round
     */
    function addRewards(
        address[] calldata providers,
        uint256[] calldata amounts,
        uint256 totalAmount,
        uint256 rewardBlock
    ) external nonReentrant onlyRole(SUPPORT_ROLE) {
        require(
            providers.length == amounts.length,
            "PositionRegistry: Length mismatch"
        );
        require(
            rewardBlock > lastRewardBlock,
            "PositionRegistry: Block must be greater than last reward block"
        );

        uint256 total = 0;
        for (uint256 i = 0; i < providers.length; i++) {
            unclaimedRewards[providers[i]] += amounts[i];
            total += amounts[i];
            emit RewardsAdded(providers[i], amounts[i]);
        }

        require(
            total == totalAmount,
            "PositionRegistry: Total amount mismatch"
        );

        telcoin.safeTransferFrom(_msgSender(), address(this), total);
        lastRewardBlock = rewardBlock;
        emit UpdateBlockStamp(rewardBlock, total);
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
     * @notice Admin function to recover ERC20 tokens sent to contract in error
     */
    function erc20Rescue(
        IERC20 token,
        address destination,
        uint256 amount
    ) external onlyRole(SUPPORT_ROLE) {
        token.safeTransfer(destination, amount);
    }
}
