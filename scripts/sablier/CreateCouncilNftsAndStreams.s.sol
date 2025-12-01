// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CouncilMember} from "../../contracts/sablier/core/CouncilMember.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Local interface used by CouncilMember for withdrawMax
import {ISablierV2Lockup} from "../../contracts/sablier/interfaces/ISablierV2Lockup.sol";

// Sablier lockup interfaces & types for creating streams
import {ISablierV2LockupLinear} from "@sablier/v2-core/src/interfaces/ISablierV2LockupLinear.sol";
import {Broker, Lockup, LockupLinear} from "@sablier/v2-core/src/types/DataTypes.sol";
import {UD60x18} from "@prb/math/src/UD60x18.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreateCouncilNftsAndStreams is Script {
    struct CouncilConfig {
        string name;
        string symbol;
        uint128 deposit;
        address safeAddress;
        address[] members;
        address proxy;
        uint256 streamId;
    }

    /// @notice deploys implementation, proxies and streams with streams connected to its corresponding proxy. 
    /// sablierSender will have governance council role which must be transferred to respective governance safe at end
    /// @param sablierSender Address that funds streams and is msg.sender in Sablier stream creation.
    /// @param tel TEL token interface.
    /// @param sablier Sablier Lockup interface for creating streams.
    /// @param sablierView Interface used by CouncilMember (withdrawMax).
    /// @param councilConfigs array of info for council NFT creation and deployment
    function deploy(
        address sablierSender,
        IERC20 tel,
        ISablierV2LockupLinear sablier,
        ISablierV2Lockup sablierView,
        CouncilConfig[] memory councilConfigs
    )
        public
        returns (address implementation, CouncilConfig[] memory updatedConfigs)
    {
        // Deploy implementation, initializing it and granting `taoSafe` the default admin role
        address taoSafe = councilConfigs[0].safeAddress;
        implementation = _deployImplementation(sablierSender, taoSafe);

        // Deploy proxies and create streams
        (updatedConfigs) = _deployProxiesAndStreams(
            sablierSender,
            tel,
            sablier,
            sablierView,
            implementation,
            councilConfigs
        );
    }

    /// @notice deploys Council Member (implementation) contract.
    /// @dev NOTE: The current audited CouncilMember version does **NOT** initialize in its constructor
    /// so it must be done explicitly here until further notice (fixes & follow-up security audit)
    /// @param deployer The deployer address running this script using the environment's `PRIVATE_KEY`
    /// @param implAdmin The address which should end up with the `DEFAULT_ADMIN_ROLE` after deployment
    function _deployImplementation(address deployer, address implAdmin) internal returns (address) {
        CouncilMember impl = new CouncilMember();
        /// @dev explicitly initialize and handle `DEFAULT_ADMIN_ROLE` granted to caller 
        impl.initialize(IERC20(address(0)), "IMPL", "IMPL", ISablierV2Lockup(address(0)), 0);
        bytes32 adminRole = impl.DEFAULT_ADMIN_ROLE();
        impl.grantRole(adminRole, implAdmin);
        impl.revokeRole(adminRole, deployer);

        address implementation = address(impl);
        console2.log("implementation deployed to: ", implementation);

        return implementation;
    }

    /// @notice deploys all proxies and streams, connecting streams to their corresponding proxies
    /// sablierSender will have governance council role which must be transferred to respective governance safe at end
    /// @param sablierSender Address that funds streams and is msg.sender in Sablier stream creation.
    /// @param tel TEL token interface.
    /// @param sablier Sablier Lockup interface for creating streams.
    /// @param sablierView Interface used by CouncilMember (withdrawMax).
    /// @param implementation Deployed Council Member instance. Proxies point to this address.
    /// @param councilConfigs array of info for council NFT creation and deployment
    function _deployProxiesAndStreams(
        address sablierSender,
        IERC20 tel,
        ISablierV2LockupLinear sablier,
        ISablierV2Lockup sablierView,
        address implementation,
        CouncilConfig[] memory councilConfigs
    ) internal returns (CouncilConfig[] memory updatedConfigs) {
        uint256 length = councilConfigs.length;
        updatedConfigs = new CouncilConfig[](length);

        for (uint256 i = 0; i < length; ++i) {
            (updatedConfigs[i]) = _deploySingleProxyAndStream(
                sablierSender,
                tel,
                sablier,
                sablierView,
                implementation,
                councilConfigs[i]
            );
        }
    }

    /// @notice deploys a single Transparent Upgradeable Proxy and connects its corresponding stream
    /// `sablierSender` will have governance council role, which must be transferred to respective council safe at end
    /// @param sablierSender Address that funds streams and is msg.sender in Sablier stream creation.
    /// @param tel TEL token interface.
    /// @param sablier Sablier Lockup interface for creating streams.
    /// @param sablierView Interface used by CouncilMember (withdrawMax).
    /// @param implementation Deployed Council Member instance. Proxies point to this address.
    /// @param councilConfig array of info for council NFT creation and deployment
    function _deploySingleProxyAndStream(
        address sablierSender,
        IERC20 tel,
        ISablierV2LockupLinear sablier,
        ISablierV2Lockup sablierView,
        address implementation,
        CouncilConfig memory councilConfig
    ) internal returns (CouncilConfig memory updatedConfig) {
        // Initialize CouncilMember, using placeholder `streamId == 0` first
        bytes memory initData = abi.encodeWithSelector(
            CouncilMember.initialize.selector,
            tel,
            councilConfig.name,
            councilConfig.symbol,
            sablierView,
            uint256(0)
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            implementation,
            sablierSender,
            initData
        );

        address proxyAddr = address(proxy);
        CouncilMember councilNFT = CouncilMember(proxyAddr);

        // Create stream
        uint256 streamId = _createV2LinearStream(
            sablier,
            tel,
            sablierSender,
            proxyAddr,
            councilConfig.deposit
        );

        councilNFT.grantRole(
            councilNFT.GOVERNANCE_COUNCIL_ROLE(),
            sablierSender
        );
        // Wire stream ID
        councilNFT.updateID(streamId);

        updatedConfig = councilConfig;
        updatedConfig.proxy = proxyAddr;
        updatedConfig.streamId = streamId;
    }

    /// @notice Creates a sablier v2 linear stream (v1.2)
    function _createV2LinearStream(
        ISablierV2LockupLinear lockupLinear,
        IERC20 tel,
        address sender,
        address recipient,
        uint128 totalAmount
    ) internal returns (uint256 streamId) {
        // 1. Approve TEL to the lockup contract (funder must be msg.sender)
        tel.approve(address(lockupLinear), totalAmount);

        // 2. Durations – 1 year, no cliff
        LockupLinear.Durations memory durations = LockupLinear.Durations({
            cliff: 0,
            total: 52 weeks
        });

        // 3. Broker - N/A - set to zero
        Broker memory broker = Broker({
            account: address(0),
            fee: UD60x18.wrap(0)
        });

        // 4. Build params
        LockupLinear.CreateWithDurations memory params = LockupLinear
            .CreateWithDurations({
                sender: sender,
                recipient: recipient,
                totalAmount: totalAmount,
                asset: tel,
                cancelable: true,
                transferable: false,
                durations: durations,
                broker: broker
            });

        // 5. Create the stream – this pulls `totalAmount` TEL from msg.sender
        streamId = lockupLinear.createWithDurations(params);
    }

    /// @notice pure function to neaten writing of council NFT parameters to script
    function getCouncilsInfo()
        internal
        pure
        returns (CouncilConfig[] memory councilConfigs)
    {
        uint256 councilCount = 6;
        councilConfigs = new CouncilConfig[](councilCount);

        // TAO Config
        councilConfigs[0].name = "Telcoin Autonomous Ops";
        councilConfigs[0].symbol = "TAONFT";
        councilConfigs[0].deposit = 454545450; // based on previous year streams
        councilConfigs[0]
            .safeAddress = 0xF4bC288d616C4f57071a57f5A4050B5e516fe7e5; //TAO: new safe

        address[] memory members0 = new address[](5);
        members0[0] = 0x9246B2C653015e28087b63dB3B9A7afE4c6eb408;
        members0[1] = 0xc1612C97537c2CC62a11FC4516367AB6F62d4B23;
        members0[2] = 0x20422E99303E9Fc438f1ce733E97E780a9877851;
        members0[3] = 0x55d932C8C20383B6eCeD977883ba1934D057a1F5;
        members0[4] = 0xE8da3e8284714D1eCb338370EC6C911e7f63344D;

        councilConfigs[0].members = members0;

        // Platform Council Config
        councilConfigs[1].name = "Telcoin Association - Platform Council";
        councilConfigs[1].symbol = "PcNFT";
        councilConfigs[1].deposit = 727272720; // based on previous year streams
        councilConfigs[1]
            .safeAddress = 0x6e130C92E6F4d71B081C4d5B664Cb210E55dBAcf; //Platform Council safe

        address[] memory members1 = new address[](8);
        members1[0] = 0x5C49F2fBf52C81d48cE95BB82efA7e760AA2F7de;
        members1[1] = 0x50360eE480809A5361439DA5d009a907e2ABf4B9;
        members1[2] = 0x36AC0C07f05E52A749e1E6Cc58ab52d1c5437556;
        members1[3] = 0xd9C06550cf95435e97e932C0F916ef4a7d24494C;
        members1[4] = 0xd4e68397406c2B95066d55Caa28752E20b92e211;
        members1[5] = 0xF8584d726A8aA2764D295e55929E727A70edd291;
        members1[6] = 0x9246B2C653015e28087b63dB3B9A7afE4c6eb408;
        members1[7] = 0xE8da3e8284714D1eCb338370EC6C911e7f63344D;

        councilConfigs[1].members = members1;

        // Treasury Council Config
        councilConfigs[2].name = "Telcoin Association - Treasury Council";
        councilConfigs[2].symbol = "TcNFT";
        councilConfigs[2].deposit = 363636360; // based on previous year streams
        councilConfigs[2]
            .safeAddress = 0x2580CCB2BE946AD98eFfA7f4B76148Bed319011c; //Treasury safe

        address[] memory members2 = new address[](4);
        members2[0] = 0x8154Ea33a9428a952371a2cf62BE8dcd0FDf7D9e;
        members2[1] = 0xcA48Aa498282bFB1161C4ce450F142E6335Edaf0;
        members2[2] = 0xc1612C97537c2CC62a11FC4516367AB6F62d4B23;
        members2[3] = 0x55d932C8C20383B6eCeD977883ba1934D057a1F5;

        councilConfigs[2].members = members2;

        // Compliance Council Config
        councilConfigs[3].name = "Telcoin Association - Compliance Council";
        councilConfigs[3].symbol = "CcNFT";
        councilConfigs[3].deposit = 363636360; // based on previous year streams
        councilConfigs[3]
            .safeAddress = 0x0454D03C2010862277262Cb306749e829ee97591; //Compliance safe

        address[] memory members3 = new address[](4);
        members3[0] = 0x5e671bB9F225F3090DA69BB374a648d0F15fF3fB;
        members3[1] = 0x19BeC353c5eFdEBEEdfA88698BcF89225F9325EE;
        members3[2] = 0x51b2695e7f21fcB56f34a3eC7d44B482C2eFE4d9;
        members3[3] = 0x51b2695e7f21fcB56f34a3eC7d44B482C2eFE4d9;

        councilConfigs[3].members = members3;

        // TAN Council Config
        councilConfigs[4].name = "Telcoin Association - TAN Council";
        councilConfigs[4].symbol = "TANNFT";
        councilConfigs[4].deposit = 545454540; // based on previous year streams
        councilConfigs[4]
            .safeAddress = 0x8Dcf8d134F22aC625A7aFb39514695801CD705b5; //TAN safe

        address[] memory members4 = new address[](6);
        members4[0] = 0x20422E99303E9Fc438f1ce733E97E780a9877851;
        members4[1] = 0x8f0D4Cd6F0Dc60E315188Ccc1C42F266E8dE86Ae;
        members4[2] = 0x20422E99303E9Fc438f1ce733E97E780a9877851;
        members4[3] = 0x20422E99303E9Fc438f1ce733E97E780a9877851;
        members4[4] = 0xf55fD26AED834091ed0620a505770e37aD3C2934;
        members4[5] = 0x20422E99303E9Fc438f1ce733E97E780a9877851;

        councilConfigs[4].members = members4;

        // TELx Council Config
        councilConfigs[5].name = "Telcoin Association - TELx Council";
        councilConfigs[5].symbol = "TELxNFT";
        councilConfigs[5].deposit = 545454540; // based on previous year streams
        councilConfigs[5]
            .safeAddress = 0x583D596b0a79C0e83C87851eA9FB1A91e80290B2; //TELx safe

        address[] memory members5 = new address[](6);
        members5[0] = 0x5490f0c24a452dFB62Bb8414A3E7aeAc1ecd19C9;
        members5[1] = 0x9DFB70a80709266C33988EEEE15f68E137CE392b;
        members5[2] = 0x20422E99303E9Fc438f1ce733E97E780a9877851;
        members5[3] = 0x9F886496a6C051Fc09499De7F70C309FCC017430;
        members5[4] = 0xA491e1FdfF62b8Cd5F1453DB1b008061F0d9C5ac;
        members5[5] = 0x5ea52e2269eb71413cC1be9Db12230A915E254D1;

        councilConfigs[5].members = members5;
    }

    /// @notice Production entry point – thin wrapper around `deploy`.
    function run() external {
        address sablierSender; // the deployer address for this script context

        // Check if we're running with a ledger or private key
        address ethFrom = vm.envOr("ETH_FROM", address(0));
        if (ethFrom != address(0)) {
            sablierSender = ethFrom;
            vm.startBroadcast(sablierSender);
        } else {
            // Fallback to private key env check
            uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
            if (pk == 0) {
                /// @dev runs outside private key/ledger use MEXC address since it reliably holds enough TEL
                sablierSender = 0x576b81F0c21EDBc920ad63FeEEB2b0736b018A58;
            } else {
                sablierSender = vm.addr(pk);
            }
        }
        console2.log("Running with msg.sender: ", sablierSender);

        IERC20 tel = IERC20(0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32);
        address sablierLockupAddr = 0x8D87c5eddb5644D1a714F85930Ca940166e465f0;

        // Same on-chain contract, two interfaces:
        ISablierV2LockupLinear sablier = ISablierV2LockupLinear(
            sablierLockupAddr
        ); // for create
        ISablierV2Lockup sablierView = ISablierV2Lockup(sablierLockupAddr); // for withdrawMax

        CouncilConfig[] memory councilConfigs = getCouncilsInfo();

        vm.startBroadcast(sablierSender);

        address implementation;
        (implementation, councilConfigs) = deploy(
            sablierSender,
            tel,
            sablier,
            sablierView,
            councilConfigs
        );

        console2.log("council configs length: ", councilConfigs.length);

        // for each proxy, mint NFTs to council members
        for (uint256 i = 0; i < councilConfigs.length; i++) {
            CouncilMember council = CouncilMember(councilConfigs[i].proxy);

            for (uint256 j = 0; j < councilConfigs[i].members.length; j++) {
                council.mint(councilConfigs[i].members[j]);
            }

            // revoke sablierSender GOVERNANCE_COUNCIL_ROLE
            council.revokeRole(
                council.GOVERNANCE_COUNCIL_ROLE(),
                sablierSender
            );

            // grant GOVERNANCE_COUNCIL_ROLE and SUPPORT_ROLE to specific council safe
            council.grantRole(
                council.GOVERNANCE_COUNCIL_ROLE(),
                councilConfigs[i].safeAddress
            );
            council.grantRole(
                council.SUPPORT_ROLE(),
                councilConfigs[i].safeAddress
            );
        }

        vm.stopBroadcast();

        // ***tests/ requires***
        // ensure implementation initializer is disabled
        (bool success, ) = address(implementation).call(
            abi.encodeWithSelector(
                CouncilMember.initialize.selector,
                IERC20(address(0)),
                "",
                "",
                ISablierV2Lockup(address(0)),
                0
            )
        );
        require(
            !success,
            "CRITICAL: implementation initializer is NOT disabled"
        );

        // Council Config tests
        for (uint256 i = 0; i < councilConfigs.length; i++) {
            address proxyAddress = councilConfigs[i].proxy;
            CouncilMember council = CouncilMember(proxyAddress);
            uint256 streamId = council._id();
            require(streamId == councilConfigs[i].streamId);
            require(council.totalSupply() == councilConfigs[i].members.length);
            require(
                council.hasRole(
                    council.GOVERNANCE_COUNCIL_ROLE(),
                    councilConfigs[i].safeAddress
                )
            );
            require(
                council.hasRole(
                    council.SUPPORT_ROLE(),
                    councilConfigs[i].safeAddress
                )
            );

            require(
                address(council._lockup()) ==
                    address(0x8D87c5eddb5644D1a714F85930Ca940166e465f0)
            );

            for (uint256 j = 0; j < councilConfigs[i].members.length; j++) {
                require(council.ownerOf(j) == councilConfigs[i].members[j]);
            }

            // **Sablier tests**
            // require streaming to proxy
            require(sablier.balanceOf(proxyAddress) > 0);

            LockupLinear.StreamLL memory sablierStreamInfo = sablier.getStream(
                streamId
            );
            require(sablierStreamInfo.sender == sablierSender);
            require(sablierStreamInfo.recipient == proxyAddress);
            require(sablierStreamInfo.isCancelable == true);
            require(sablierStreamInfo.wasCanceled == false);
            require(sablierStreamInfo.asset == tel);
            require(sablierStreamInfo.endTime > sablierStreamInfo.startTime);
            require(sablierStreamInfo.isDepleted == false);
            require(sablierStreamInfo.isStream == true);
            require(sablierStreamInfo.isTransferable == false);
            require(
                sablierStreamInfo.amounts.deposited == councilConfigs[i].deposit
            );
            require(sablierStreamInfo.amounts.withdrawn == 0);
            require(sablierStreamInfo.amounts.refunded == 0);
            require(sablierStreamInfo.cliffTime == 0);
        }
    }
}
