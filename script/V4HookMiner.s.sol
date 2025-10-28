// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TELxIncentiveHook} from "contracts/telx/core/TELxIncentiveHook.sol";
import {PositionRegistry} from "contracts/telx/core/PositionRegistry.sol";
import {TELxSubscriber} from "contracts/telx/core/TELxSubscriber.sol";
import {IPositionRegistry} from "contracts/telx/interfaces/IPositionRegistry.sol";

/// @notice Mines the v4 hook address and deploys its infrastructure
contract V4HookMinerDeployer is Script {

    address deployer = ;
    address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address support;
    IERC20 tel;
    address eth = address(0x0);

    address poolManager;
    address positionManager;
    address universalRouter;
    address stateView;
    bytes32 positionRegistrySalt = bytes32(0x0);
    bytes32 telxSubscriberSalt = bytes32(0x0);

    PositionRegistry positionRegistry;
    TELxIncentiveHook telxIncentiveHook;
    TELxSubscriber telxSubscriber;

    PoolKey public poolKey;
    
    function setUp() public {
        // configure for the current chain
        support = ;
        tel = IERC20(0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32);
        poolManager = 0x67366782805870060151383F4BbFF9daB53e5cD6;
        positionManager = 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9; 
        universalRouter = 0x1095692A6237d83C6a72F3F5eFEdb9A670C49223;
        stateView = 0x5eA1bD7974c8A611cBAB0bDCAFcB1D9CC9b3BA5a;

        // deploy registry and subscriber
        positionRegistry = new PositionRegistry{salt: positionRegistrySalt}(tel, IPoolManager(address(poolManager)), IPositionManager(address(positionManager)), StateView(address(stateView)));
        telxSubscriber = new TELxSubscriber{salt: telxSubscriberSalt}(IPositionRegistry(address(positionRegistry)), address(positionManager));
    }

    function run() public {
        // specific flags encoded in the address
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );

        // Mine salt that will produce hook address with correct flags
        bytes memory constructorArgs = abi.encode(poolManager, positionManager, positionRegistry);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(TELxIncentiveHook).creationCode, constructorArgs);

        // deterministically deploy the hook using CREATE2
        vm.startBroadcast(deployer);
        telxIncentiveHook = new TELxIncentiveHook{salt: salt}(IPoolManager(poolManager), positionManager, positionRegistry);
        require(address(telxIncentiveHook) == hookAddress, "V4HookMinerDeployer: hook address mismatch");

        // grant relevant roles
        positionRegistry.grantRole(positionRegistry.SUPPORT_ROLE(), support);
        positionRegistry.grantRole(positionRegistry.UNI_HOOK_ROLE(), address(telxIncentiveHook));
        positionRegistry.grantRole(positionRegistry.SUBSCRIBER_ROLE(), address(telxSubscriber));

        // initialize pool(s)
        uint160 sqrtPriceX96 = ;
        // create TEL-USDC pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(eth)),
            currency1: Currency.wrap(address(tel)),
            fee: 3000, // todo: stablecoin pool uses different fee!
            tickSpacing: 60, //todo: stablecoin pool uses different spacing!
            hooks: IHooks(hookAddress)
        });
        int24 returnedTick = poolManager.initialize(poolKey, sqrtPriceX96);

        vm.stopBroadcast();

        // sanity asserts
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        assertEq(returnedTick, tick);

        assert(positionRegistry.validPool(poolKey.toId()));
        (Currency currency0, Currency currency1, uint24 fee, int24 spacing, IHooks hooks) = positionRegistry.initializedPoolKeys(poolKey.toId());
        assert(Currency.unwrap(currency0) == Currency.unwrap(poolKey.currency0));
        assert(Currency.unwrap(currency1) == Currency.unwrap(poolKey.currency1));
        assert(fee == poolKey.fee);
        assert(spacing == poolKey.tickSpacing);
        assert(address(hooks) == address(poolKey.hooks));

        assert(address(telxIncentiveHook.registry()) ==  address(positionRegistry));
        Hooks.Permissions memory permissions = telxIncentiveHook.getHookPermissions();
        assert(permissions.beforeInitialize);
        assert(permissions.afterAddLiquidity);
        assert(permissions.afterRemoveLiquidity);

        assert(address(positionRegistry.telcoin()) == address(tel));
        assert(positionRegistry.hasRole(positionRegistry.UNI_HOOK_ROLE(), address(telxIncentiveHook)));
        assert(positionRegistry.hasRole(positionRegistry.SUPPORT_ROLE(), support));
        assert(positionRegistry.hasRole(positionRegistry.SUBSCRIBER_ROLE(), address(telxSubscriber)));
    }
}