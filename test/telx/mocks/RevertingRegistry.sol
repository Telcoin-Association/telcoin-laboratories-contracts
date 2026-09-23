// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RevertingRegistry
/// @notice A registry stand-in that reverts on every call. Models the worst a misconfigured or
///         broken registry can do to the subscriber, so the notification paths v4 bubbles into the
///         LP's own transaction can be shown to complete regardless.
contract RevertingRegistry {
    error AlwaysReverts();

    fallback() external {
        revert AlwaysReverts();
    }
}
