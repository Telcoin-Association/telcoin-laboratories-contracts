// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockRouter
/// @notice Mock router that implements IMsgSender (the `msgSender()` selector Uniswap v4
///         peripherals use to attribute the original user behind a router call). Used to
///         exercise PositionRegistry / TELxSubscriber `_resolveUser` paths that trust a
///         registered router.
contract MockRouter {
    address private _sender;

    constructor(address sender_) {
        _sender = sender_;
    }

    function msgSender() external view returns (address) {
        return _sender;
    }
}
