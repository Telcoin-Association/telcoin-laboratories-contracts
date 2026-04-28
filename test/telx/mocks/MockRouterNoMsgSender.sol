// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockRouterNoMsgSender
/// @notice Mock router that intentionally does NOT implement IMsgSender. Used to exercise
///         the revert path in PositionRegistry / TELxSubscriber `_resolveUser` when a
///         registered router doesn't expose `msgSender()`.
contract MockRouterNoMsgSender {
// intentionally empty - no msgSender function
}
