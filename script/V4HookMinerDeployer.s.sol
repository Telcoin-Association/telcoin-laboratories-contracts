// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TELxIncentiveHook} from "contracts/telx/core/TELxIncentiveHook.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";

/// @notice Mines the v4 hook address and deploys its infrastructure
/**
 *  Usage:
 *     forge script script/V4HookMinerDeployer.s.sol:V4HookMinerDeployer \
 *         --rpc-url $BASE_RPC_URL \
 *         --private-key $DEPLOYER_PK \
 *         --sig "run(string,uint160)" \
 *         "BASE_ETH_TEL" <YOUR_SQRT_PRICE_X96>
 */
contract V4HookMinerDeployer is Script {
    using console for string;
    using PoolIdLibrary for bytes32;

    struct ChainConfig {
        address poolManager;
        address positionManager;
        address universalRouter;
        address stateView;
        address telToken;
        address wethToken; // Use WETH on Polygon
        address nativeToken; // ETH on Base, matic on Polygon
        address usdcToken;
        address emxnToken;
        address supportSafe;
    }

    struct PoolConfig {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
    }

    // --- Constants ---
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant REGISTRY_SALT = keccak256("TELx_PositionRegistry_v1");
    bytes32 constant SUBSCRIBER_SALT = keccak256("TELx_Subscriber_v1");
    bytes32 constant POLYGON_WETH_TEL_POOLID =
        bytes32(0x9a005a0c12cc2ef01b34e9a7f3fb91a0e6304d377b5479bd3f08f8c29cdf5deb);
    bytes32 constant POLYGON_USDC_EMXN_POOLID =
        bytes32(0xfd56605f7f4620ab44dfc0860d70b9bd1d1f648a5a74558491b39e816a10b99a);
    bytes32 constant BASE_ETH_TEL_POOLID = bytes32(0xb6d004fca4f9a34197862176485c45ceab7117c86f07422d1fe3d9cfd6e9d1da);

    // --- Config Storage ---
    mapping(uint256 => ChainConfig) public chainConfigs;
    // Keyed by keccak256("TOKEN0_SYMBOL/TOKEN1_SYMBOL_FEE")
    mapping(bytes32 => PoolConfig) public poolConfigs;

    address deployer;
    PositionRegistry positionRegistry;
    TELxIncentiveHook telxIncentiveHook;
    TELxSubscriber telxSubscriber;
    address hookAddress;

    function setUp() public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        deployer = vm.addr(deployerPk);
        require(deployer == 0xc1612C97537c2CC62a11FC4516367AB6F62d4B23, "WRONG DEPLOYER"); //todo

        // Polygon Config
        uint256 polygonChainId = 137;
        chainConfigs[polygonChainId] = ChainConfig({
            poolManager: vm.envAddress("POLYGON_POOL_MANAGER"),
            positionManager: vm.envAddress("POLYGON_POSITION_MANAGER"),
            universalRouter: vm.envAddress("POLYGON_UNIVERSAL_ROUTER"),
            stateView: vm.envAddress("POLYGON_STATE_VIEW"),
            telToken: vm.envAddress("POLYGON_TEL_TOKEN"),
            wethToken: vm.envAddress("POLYGON_WETH_TOKEN"),
            nativeToken: address(0x0), // NOT_APPLICABLE
            usdcToken: vm.envAddress("POLYGON_USDC_TOKEN"),
            emxnToken: vm.envAddress("POLYGON_EMXN_TOKEN"),
            supportSafe: vm.envAddress("POLYGON_SUPPORT_SAFE")
        });
        poolConfigs[keccak256("POLYGON_WETH_TEL")] = PoolConfig({
            currency0: chainConfigs[polygonChainId].wethToken, // WETH is currency0
            currency1: chainConfigs[polygonChainId].telToken, // TEL is currency1
            fee: 3000, // 0.3% fee = 3000
            tickSpacing: 60
        });
        poolConfigs[keccak256("POLYGON_USDC_EMXN")] = PoolConfig({
            currency0: chainConfigs[polygonChainId].usdcToken, // USDC is currency0
            currency1: chainConfigs[polygonChainId].emxnToken, // EMXN is currency1
            fee: 500, // 0.05% fee = 500
            tickSpacing: 10
        });

        // --- Base Config ---
        uint256 baseChainId = 8453;
        chainConfigs[baseChainId] = ChainConfig({
            poolManager: vm.envAddress("BASE_POOL_MANAGER"),
            positionManager: vm.envAddress("BASE_POSITION_MANAGER"),
            universalRouter: vm.envAddress("BASE_UNIVERSAL_ROUTER"),
            stateView: vm.envAddress("BASE_STATE_VIEW"),
            telToken: vm.envAddress("BASE_TEL_TOKEN"),
            wethToken: vm.envAddress("BASE_WETH_TOKEN"), // NOT APPLICABLE
            nativeToken: address(0x0),
            usdcToken: vm.envAddress("BASE_USDC_TOKEN"), // NOT APPLICABLE
            emxnToken: vm.envAddress("BASE_EMXN_TOKEN"), // NOT APPLICABLE
            supportSafe: vm.envAddress("BASE_SUPPORT_SAFE")
        });
        poolConfigs[keccak256("BASE_ETH_TEL")] = PoolConfig({
            currency0: chainConfigs[baseChainId].nativeToken,
            currency1: chainConfigs[baseChainId].telToken,
            fee: 3000, // 0.3% fee = 3000
            tickSpacing: 60
        });

        // add any future chains and pools here
    }

    /// @notice Valid inputs for `targetPool` are supported pools named by `CHAIN_CURRENCY0_CURRENCY1`, ie:
    /// `"BASE_ETH_TEL" || "POLYGON_WETH_TEL" || "POLYGON_USDC_EMXN"`
    function run(string memory targetPool, uint160 sqrtPriceX96) public {
        // 1. Determine Target Chain/Pool & Load Config
        uint256 chainId = block.chainid;
        ChainConfig storage config = _getChainConfig(chainId);
        PoolConfig storage poolConfig = _getPoolConfig(bytes(targetPool));

        // Validate Price Input
        require(sqrtPriceX96 > 0, "Initial sqrtPriceX96 must be provided and > 0");

        // 2. Deploy Contracts via CREATE2
        vm.startBroadcast(deployer); // Start broadcasting state changes
        _deployContracts(config);

        // 3. Configure Roles & Router
        _configureRoles(config);

        // 4. Initialize the Target Pool
        PoolKey memory targetPoolKey = _getPoolKey(poolConfig); // must be after _deployContracts
        _initializePool(config, poolConfig, targetPoolKey, sqrtPriceX96);

        vm.stopBroadcast();

        // 5. Sanity Checks (optional but recommended)
        _postDeploymentChecks(config, poolConfig, targetPoolKey);

        console.log("Deployment Successful!");
        console.log("  PositionRegistry: %s", address(positionRegistry));
        console.log("  TELxSubscriber: %s", address(telxSubscriber));
        console.log("  TELxIncentiveHook: %s", address(telxIncentiveHook));
        console.log("  Initialized Pool: %s", targetPool);
    }

    function _deployContracts(ChainConfig storage config) internal {
        console.log("Deploying contracts via CREATE2...");

        // A. Deploy PositionRegistry
        bytes memory registryConstructorArgs = abi.encode(
            IERC20(config.telToken),
            IPoolManager(config.poolManager),
            IPositionManager(config.positionManager),
            StateView(config.stateView),
            deployer
        );
        bytes memory registryBytecode = abi.encodePacked(type(PositionRegistry).creationCode, registryConstructorArgs);
        address predictedRegistryAddress =
            vm.computeCreate2Address(REGISTRY_SALT, keccak256(registryBytecode), CREATE2_DEPLOYER);

        // Deploy only if not already deployed at the predicted address
        if (predictedRegistryAddress.code.length == 0) {
            // positionRegistry = PositionRegistry(payable(Create2.deploy(0, REGISTRY_SALT, registryBytecode))); //todo
            positionRegistry = new PositionRegistry{salt: REGISTRY_SALT}(
                IERC20(config.telToken),
                IPoolManager(config.poolManager),
                IPositionManager(config.positionManager),
                StateView(config.stateView),
                deployer
            );
            require(address(positionRegistry) == predictedRegistryAddress, "Registry address mismatch");
            console.log("  Deployed PositionRegistry at: %s", address(positionRegistry));
        } else {
            positionRegistry = PositionRegistry(payable(predictedRegistryAddress));
            console.log("  Found existing PositionRegistry at: %s", address(positionRegistry));
        }

        // B. Deploy TELxSubscriber
        bytes memory subscriberConstructorArgs =
            abi.encode(IPositionRegistry(address(positionRegistry)), config.positionManager);
        bytes memory subscriberBytecode = abi.encodePacked(type(TELxSubscriber).creationCode, subscriberConstructorArgs);
        address predictedSubscriberAddress =
            vm.computeCreate2Address(SUBSCRIBER_SALT, keccak256(subscriberBytecode), CREATE2_DEPLOYER);

        if (predictedSubscriberAddress.code.length == 0) {
            telxSubscriber = new TELxSubscriber{salt: SUBSCRIBER_SALT}(
                IPositionRegistry(address(positionRegistry)), config.positionManager
            );
            // telxSubscriber = new TELxSubscriber(payable(Create2.deploy(0, SUBSCRIBER_SALT, subscriberBytecode))); //todo
            require(address(telxSubscriber) == predictedSubscriberAddress, "Subscriber address mismatch");
            console.log("  Deployed TELxSubscriber at: %s", address(telxSubscriber));
        } else {
            telxSubscriber = TELxSubscriber(payable(predictedSubscriberAddress));
            console.log("  Found existing TELxSubscriber at: %s", address(telxSubscriber));
        }

        // C. Mine and Deploy TELxIncentiveHook
        console.log("  Mining hook salt...");
        // specific flags encoded in the address
        uint160 flags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

        bytes memory hookConstructorArgs =
            abi.encode(config.poolManager, config.positionManager, address(positionRegistry));
        bytes memory hookCreationCode = type(TELxIncentiveHook).creationCode;
        (address predictedHookAddress, bytes32 hookSalt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, hookCreationCode, hookConstructorArgs);
        hookAddress = predictedHookAddress; // Store globally for pool initialization

        console.log(" !!! Found salt for hook:");
        console.logBytes32(hookSalt);
        console.log(" !!! Predicted hook address: %s", predictedHookAddress);

        if (predictedHookAddress.code.length == 0) {
            telxIncentiveHook = new TELxIncentiveHook{salt: hookSalt}(
                IPoolManager(config.poolManager), config.positionManager, IPositionRegistry(address(positionRegistry))
            );
            require(address(telxIncentiveHook) == predictedHookAddress, "Hook address mismatch");
            console.log("  Deployed TELxIncentiveHook");
        } else {
            telxIncentiveHook = TELxIncentiveHook(payable(predictedHookAddress));
            console.log("  Found existing TELxIncentiveHook at: %s", address(telxIncentiveHook));
        }
    }

    // grant relevant roles and add universal router
    function _configureRoles(ChainConfig storage config) internal {
        console.log("Configuring roles...");
        bytes32 supportRole = positionRegistry.SUPPORT_ROLE();
        bytes32 hookRole = positionRegistry.UNI_HOOK_ROLE();
        bytes32 subscriberRole = positionRegistry.SUBSCRIBER_ROLE();

        // grant roles where necessary to meet config
        if (!positionRegistry.hasRole(supportRole, config.supportSafe)) {
            positionRegistry.grantRole(supportRole, config.supportSafe);
        }
        if (!positionRegistry.hasRole(supportRole, deployer)) {
            positionRegistry.grantRole(supportRole, deployer); // revoked later after router setup
        }
        if (!positionRegistry.hasRole(hookRole, address(telxIncentiveHook))) {
            positionRegistry.grantRole(hookRole, address(telxIncentiveHook));
        }
        if (!positionRegistry.hasRole(subscriberRole, address(telxSubscriber))) {
            positionRegistry.grantRole(subscriberRole, address(telxSubscriber));
        }

        // set universal router as trusted
        positionRegistry.updateRouter(config.universalRouter, true);
        positionRegistry.renounceRole(supportRole, deployer); // Renounce setup role
        console.log("  Roles configured.");
    }

    function _initializePool(
        ChainConfig storage config,
        PoolConfig storage poolConfig,
        PoolKey memory key,
        uint160 sqrtPriceX96
    ) internal {
        console.log("Initializing pool...");

        // Ensure currencies are sorted correctly for PoolKey
        address addr0 = poolConfig.currency0;
        address addr1 = poolConfig.currency1;
        require(addr0 < addr1, "Unsorted currency0 and currency1");

        // The actual initialization call to Uniswap
        int24 returnedTick = IPoolManager(config.poolManager).initialize(key, sqrtPriceX96);

        require(returnedTick == TickMath.getTickAtSqrtPrice(sqrtPriceX96), "Mismatching tick");
        console.log("  Pool initialized.");
    }

    function _postDeploymentChecks(ChainConfig storage chainConfig, PoolConfig storage poolConfig, PoolKey memory key)
        internal
        view
    {
        console.log("Running post-deployment checks...");
        address addr0 = poolConfig.currency0;
        address addr1 = poolConfig.currency1;
        require(addr0 < addr1, "Unsorted currency0 and currency1");

        // --- Hook Checks ---
        require(address(telxIncentiveHook.registry()) == address(positionRegistry), "Hook registry mismatch");
        Hooks.Permissions memory permissions = telxIncentiveHook.getHookPermissions();
        require(permissions.beforeInitialize, "!beforeInitialize");
        require(permissions.afterAddLiquidity, "!afterAddLiquidity");
        require(permissions.afterRemoveLiquidity, "!afterRemoveLiquidity");

        // --- Registry Checks ---
        require(address(positionRegistry.telcoin()) == chainConfig.telToken, "Registry TEL mismatch");
        require(
            positionRegistry.hasRole(positionRegistry.UNI_HOOK_ROLE(), address(telxIncentiveHook)), "!UNI_HOOK_ROLE"
        );
        require(positionRegistry.hasRole(positionRegistry.SUPPORT_ROLE(), chainConfig.supportSafe), "!SUPPORT_ROLE");
        require(
            positionRegistry.hasRole(positionRegistry.SUBSCRIBER_ROLE(), address(telxSubscriber)), "!SUBSCRIBER_ROLE"
        );
        require(positionRegistry.isActiveRouter(chainConfig.universalRouter), "!router");

        // --- Pool Initialization Check ---
        require(positionRegistry.validPool(key.toId()), "Pool not valid in registry");
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            positionRegistry.initializedPoolKeys(key.toId());
        require(Currency.unwrap(currency0) == Currency.unwrap(key.currency0), "Stored C0 mismatch");
        require(Currency.unwrap(currency1) == Currency.unwrap(key.currency1), "Stored C1 mismatch");
        require(fee == key.fee, "Stored fee mismatch");
        require(tickSpacing == key.tickSpacing, "Stored spacing mismatch");
        require(address(hooks) == address(key.hooks), "Stored hook mismatch");

        console.log("  Checks passed.");
    }

    // Helper to get chain config safely
    function _getChainConfig(uint256 chainId) internal view returns (ChainConfig storage) {
        require(chainConfigs[chainId].poolManager != address(0), "Unsupported chainId");
        return chainConfigs[chainId];
    }

    // Helper to get pool config safely
    function _getPoolConfig(bytes memory targetPool) internal view returns (PoolConfig storage) {
        require(
            keccak256(targetPool) == keccak256("BASE_ETH_TEL") || keccak256(targetPool) == keccak256("POLYGON_WETH_TEL")
                || keccak256(targetPool) == keccak256("POLYGON_USDC_EMXN"),
            "Unsupported pool"
        );

        PoolConfig storage poolConfig = poolConfigs[keccak256(targetPool)];
        address addr0 = poolConfig.currency0;
        address addr1 = poolConfig.currency1;
        require(
            addr0 != address(type(uint160).max) && addr1 != address(type(uint160).max) && addr1 != address(0),
            "Unsupported poolId"
        );

        return (poolConfig);
    }

    // Helper to get pool key safely, must occur after `_deployContracts`
    function _getPoolKey(PoolConfig storage poolConfig) internal view returns (PoolKey memory) {
        address addr0 = poolConfig.currency0;
        address addr1 = poolConfig.currency1;
        require(
            addr0 != address(type(uint160).max) && addr1 != address(type(uint160).max) && addr1 != address(0),
            "Unsupported poolId"
        );

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(addr0),
            currency1: Currency.wrap(addr1),
            fee: poolConfig.fee,
            tickSpacing: poolConfig.tickSpacing,
            hooks: IHooks(hookAddress)
        });

        return (key);
    }
}
