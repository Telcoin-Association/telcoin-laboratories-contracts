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
import {PolygonAddresses} from "../shared/PolygonAddresses.sol";

contract CreateCouncilNftsAndStreams is Script {
    /// @notice When every year-3 stream starts: 2026-11-25 18:12:37 UTC, the moment the last
    ///         year-2 council stream ends. The year-2 streams (IDs 666-671) were created in
    ///         separate blocks and end between 18:11:19 and 18:12:37 UTC, so starting at the
    ///         latest end means no year-3 stream overlaps any year-2 stream.
    /// @dev    A fixed start lets the script be broadcast ahead of time: the streams are funded
    ///         at creation but nothing vests until this moment.
    uint40 public constant STREAM_START_TIME = 1_795_630_357;

    /// @notice How long before `STREAM_START_TIME` the script must finish broadcasting.
    /// @dev    Every mint after a council's first triggers `_retrieve()`, which splits whatever
    ///         has vested among the members minted so far. If a stream has already started when
    ///         the NFTs are minted, everything vested up to then goes to the first member alone.
    ///         Minting before the stream is wired is not possible: until `updateID` the proxy
    ///         points at stream 0, which does not exist, so the second mint would revert. The
    ///         script therefore refuses to run this close to the start. The margin covers a
    ///         Ledger broadcast, where each transaction is confirmed by hand.
    uint40 public constant BROADCAST_MARGIN = 1 hours;

    /// @notice How long each stream runs, with no cliff. Matches year 2.
    uint40 public constant STREAM_DURATION = 52 weeks;

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
    /// @dev Constructor calls `_disableInitializers()`, permanently locking the implementation.
    function _deployImplementation(
        address,
        address
    ) internal returns (address) {
        CouncilMember impl = new CouncilMember();
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

        // 2. Timestamps - fixed start, 52 weeks, no cliff
        LockupLinear.Timestamps memory timestamps = LockupLinear.Timestamps({
            start: STREAM_START_TIME,
            cliff: 0,
            end: STREAM_START_TIME + STREAM_DURATION
        });

        // 3. Broker - N/A - set to zero
        Broker memory broker = Broker({
            account: address(0),
            fee: UD60x18.wrap(0)
        });

        // 4. Build params
        LockupLinear.CreateWithTimestamps memory params = LockupLinear
            .CreateWithTimestamps({
                sender: sender,
                recipient: recipient,
                totalAmount: totalAmount,
                asset: tel,
                cancelable: true,
                transferable: false,
                timestamps: timestamps,
                broker: broker
            });

        // 5. Create the stream - this pulls `totalAmount` TEL from msg.sender
        streamId = lockupLinear.createWithTimestamps(params);
    }

    /// @notice Pure function returning the council-NFT parameter table for
    ///         this deployment. Exposed as `public` (not `internal`) so fork
    ///         tests can derive the total TEL deposit requirement at runtime
    ///         from the same source-of-truth the deploy uses.
    function getCouncilsInfo()
        public
        pure
        returns (CouncilConfig[] memory councilConfigs)
    {
        uint256 councilCount = 6;
        councilConfigs = new CouncilConfig[](councilCount);

        // TAO Config
        councilConfigs[0].name = "Telcoin Autonomous Ops";
        councilConfigs[0].symbol = "TAONFT";
        councilConfigs[0].deposit = 4_545_454.5e18; // TEL v3 (18 decimals); same TEL as year-2 stream 666
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
        councilConfigs[1].deposit = 7_272_727.2e18; // TEL v3 (18 decimals); same TEL as year-2 stream 667
        councilConfigs[1]
            .safeAddress = 0x6e130C92E6F4d71B081C4d5B664Cb210E55dBAcf; //Platform Council safe

        address[] memory members1 = new address[](8);
        members1[0] = 0x5C49F2fBf52C81d48cE95BB82efA7e760AA2F7de;
        members1[1] = 0x9246B2C653015e28087b63dB3B9A7afE4c6eb408; // also holds members1[6]: two Platform seats
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
        councilConfigs[2].deposit = 3_636_363.6e18; // TEL v3 (18 decimals); same TEL as year-2 stream 668
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
        councilConfigs[3].deposit = 3_636_363.6e18; // TEL v3 (18 decimals); same TEL as year-2 stream 669
        councilConfigs[3]
            .safeAddress = 0x0454D03C2010862277262Cb306749e829ee97591; //Compliance safe

        address[] memory members3 = new address[](4);
        members3[0] = 0x5e671bB9F225F3090DA69BB374a648d0F15fF3fB;
        members3[1] = 0x19BeC353c5eFdEBEEdfA88698BcF89225F9325EE;
        members3[2] = 0x51b2695e7f21fcB56f34a3eC7d44B482C2eFE4d9;
        members3[3] = 0x4EF34f7B73FE070e007813DBcf62A426eaa45E73;

        councilConfigs[3].members = members3;

        // TAN Council Config
        councilConfigs[4].name = "Telcoin Association - TAN Council";
        councilConfigs[4].symbol = "TANNFT";
        councilConfigs[4].deposit = 5_454_545.4e18; // TEL v3 (18 decimals); same TEL as year-2 stream 670
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
        councilConfigs[5].deposit = 5_454_545.4e18; // TEL v3 (18 decimals); same TEL as year-2 stream 671
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

    /// @notice Production entry point - resolves the signer from env and
    ///         delegates to `runWithSigner`.
    function run() external {
        address sablierSender; // the deployer address for this script context

        // Check if we're running with a ledger or private key
        address ethFrom = vm.envOr("ETH_FROM", address(0));
        if (ethFrom != address(0)) {
            sablierSender = ethFrom;
        } else {
            // Fallback to private key env check
            uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
            if (pk == 0) {
                /// @dev No signer configured: simulate as an address that holds enough TEL v3 on
                ///      Polygon, so a dry run gets past the stream deposits. It can never broadcast,
                ///      since its key is not available here.
                sablierSender = 0x20dAAcb0864fF9a5e07d05Ea16Fa56cD00fdC16D;
            } else {
                sablierSender = vm.addr(pk);
            }
        }
        runWithSigner(sablierSender);
    }

    /// @notice Explicit-signer entry point. Production `run()` delegates here,
    ///         and fork tests call this directly with a controlled signer.
    ///         Mirrors the `runWithSigner` pattern in UpgradeCouncilMember.s.sol.
    function runWithSigner(address sablierSender) public {
        console2.log("Running with msg.sender: ", sablierSender);
        require(
            block.timestamp + BROADCAST_MARGIN <= STREAM_START_TIME,
            "Too close to STREAM_START_TIME: NFTs must be minted before the streams start vesting"
        );

        // Council streams pay out in TEL v3 (18 decimals) from year 3 onwards.
        IERC20 tel = IERC20(PolygonAddresses.TEL_V3);
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
            require(sablierStreamInfo.startTime == STREAM_START_TIME);
            require(
                sablierStreamInfo.endTime == STREAM_START_TIME + STREAM_DURATION
            );
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
