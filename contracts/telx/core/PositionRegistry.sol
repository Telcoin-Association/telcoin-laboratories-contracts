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
        bytes32 indexed positionId,
        address indexed provider,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// @notice Emitted when a position's liquidity reaches zero and is removed
    event PositionRemoved(
        bytes32 indexed positionId,
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

    bytes32 public constant UNI_HOOK_ROLE = keccak256("UNI_HOOK_ROLE");
    bytes32 public constant SUPPORT_ROLE = keccak256("SUPPORT_ROLE");

    uint256 constant MAX_POSITIONS = 100;

    mapping(address => bytes32[]) internal providerPositions;
    mapping(address => uint256) public unclaimedRewards;
    mapping(bytes32 => Position) public positions;
    mapping(PoolId => uint8) public telcoinPosition;
    mapping(address => bool) public routers;
    bytes32[] public activePositionIds;

    IERC20 public immutable telcoin;
    uint256 public lastRewardBlock;
    IPoolManager public immutable poolManager;

    /**
     * @notice Initializes the registry with a reward token
     * @param _telcoin The ERC20 token used to pay LP rewards
     */
    constructor(IERC20 _telcoin, IPoolManager _poolManager) {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        telcoin = _telcoin;
        poolManager = _poolManager;
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
     * @notice Computes a unique identifier for a position
     */
    function getPositionId(
        address provider,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper
    ) public pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(provider, poolId, tickLower, tickUpper));
    }

    /**
     * @notice Returns position metadata given its ID
     */
    function getPosition(
        bytes32 positionId
    ) external view returns (Position memory) {
        return positions[positionId];
    }

    function getPositionsByStaker(
        address staker
    ) external view returns (bytes32[] memory) {
        return providerPositions[staker];
    }

    /**
     * @notice Lists all active tracked position IDs
     */
    function getAllActivePositionIds()
        external
        view
        returns (bytes32[] memory)
    {
        return activePositionIds;
    }

    /**
     * @notice Returns all currently active LP positions
     */
    function getAllActivePositions()
        external
        view
        override
        returns (Position[] memory)
    {
        uint256 length = activePositionIds.length;
        Position[] memory result = new Position[](length);

        for (uint256 i = 0; i < length; i++) {
            result[i] = positions[activePositionIds[i]];
        }

        return result;
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
     * @param positionId The position identifier
     */
    function computeVotingWeight(
        bytes32 positionId
    ) external view returns (uint256) {
        Position storage pos = positions[positionId];
        if (pos.liquidity == 0) return 0;

        PoolId poolId = positions[positionId].poolId;
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

        uint256 priceX96 = FullMath.mulDiv(
            uint256(sqrtPriceX96),
            uint256(sqrtPriceX96),
            2 ** 96
        );

        uint8 index = telcoinPosition[pos.poolId];

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
        address provider,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) external onlyRole(UNI_HOOK_ROLE) {
        // Does not fail on invalid poolId, just skips update
        if (telcoinPosition[poolId] == 0) {
            return;
        }

        require(
            liquidityDelta != type(int128).min,
            "PositionRegistry: Invalid liquidity delta"
        );

        bytes32 positionId = getPositionId(
            provider,
            poolId,
            tickLower,
            tickUpper
        );
        Position storage pos = positions[positionId];

        if (liquidityDelta > 0) {
            if (pos.liquidity == 0) {
                //Does not allow excessive positions
                if (providerPositions[provider].length >= MAX_POSITIONS) {
                    return;
                }
                pos.provider = provider;
                pos.poolId = poolId;
                pos.tickLower = tickLower;
                pos.tickUpper = tickUpper;
                activePositionIds.push(positionId);
                providerPositions[provider].push(positionId);
            }

            pos.liquidity += uint128(liquidityDelta);
            emit PositionUpdated(
                positionId,
                provider,
                poolId,
                tickLower,
                tickUpper,
                pos.liquidity
            );
        } else {
            uint128 delta = uint128(-liquidityDelta);
            pos.liquidity -= delta;

            if (pos.liquidity == 0) {
                delete positions[positionId];
                for (uint256 i = 0; i < activePositionIds.length; i++) {
                    if (activePositionIds[i] == positionId) {
                        activePositionIds[i] = activePositionIds[
                            activePositionIds.length - 1
                        ];
                        activePositionIds.pop();
                        break;
                    }
                }

                bytes32[] storage list = providerPositions[provider];
                for (uint256 j = 0; j < list.length; j++) {
                    if (list[j] == positionId) {
                        list[j] = list[list.length - 1];
                        list.pop();
                        break;
                    }
                }

                emit PositionRemoved(
                    positionId,
                    provider,
                    poolId,
                    tickLower,
                    tickUpper
                );
            } else {
                emit PositionUpdated(
                    positionId,
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
