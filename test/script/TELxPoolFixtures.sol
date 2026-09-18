// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolsJson} from "../../script/telx/base/PoolsJson.sol";

/// @title TELxPoolFixtures
/// @notice Stand-in `pools.json` values for the fork tests. The checked-in file ships with every
///         amount and floor at zero, because those are business decisions; the tests need real
///         figures to exercise the price, the mint and the floor derivation, so they carry their
///         own here and inject them through the scripts' virtual `_poolParams`.
library TELxPoolFixtures {
    error UnknownFixture(string poolName);

    /// @notice Plausible seed parameters for every catalog pool: TEL at about 0.005 USD, eMXN at
    ///         about 18 per USD, ETH at about 2,830 USD, a +/-10% band (+/-1% for the stable
    ///         pair), and a floor worth about one dollar of currency1 in the narrowest band.
    function params(string memory poolName) internal pure returns (PoolsJson.PoolParams memory p) {
        p.widthBps = 1000;
        p.maxTickDeviation = 50;
        p.slippageBps = 50;
        bytes32 h = keccak256(bytes(poolName));

        if (h == keccak256("ETHEREUM_ETH_TEL") || h == keccak256("BASE_ETH_TEL") || h == keccak256("POLYGON_WETH_TEL"))
        {
            p.amount0Human = 10; // ETH or WETH
            p.amount1Human = 5_660_380; // TEL v3
            p.minPositionValue1Human = 200; // TEL, about a dollar
        } else if (
            h == keccak256("ETHEREUM_EUSD_TEL") || h == keccak256("POLYGON_EUSD_TEL") || h == keccak256("BASE_EUSD_TEL")
        ) {
            p.amount0Human = 100_000; // eUSD
            p.amount1Human = 20_000_000; // TEL v3
            p.minPositionValue1Human = 200;
        } else if (h == keccak256("POLYGON_EUSD_EMXN")) {
            p.amount0Human = 100_000; // eUSD
            p.amount1Human = 1_800_000; // eMXN
            p.widthBps = 100;
            p.minPositionValue1Human = 20; // eMXN, about a dollar
        } else {
            revert UnknownFixture(poolName);
        }
    }
}
