// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

///////////////////
/// IART Interface
///////////////////

interface IART {
    event Update(
        uint256 indexed x,
        uint256 indexed y,
        bytes1 value,
        address author,
        uint32 layer
    );
    event Edit(address indexed editor, uint256 indexed numChanges);
    event UserBanned(address indexed user);
    event UserRestored(address indexed user);

    // =========================
    //       CUSTOM ERRORS
    // =========================

    error Frozen();
    error Banned();
    error InvalidPixel(uint256 x, uint256 y);
    error ColorZeroNotAllowed();
    error ArrayMismatch();
    error InsufficientTribute(uint256 paid, uint256 required);
    error InvalidSeedLength();
    error SeedContainsZero();
    error NotOwner();
    error ZeroAddress();

    function transferOwnership(address newOwner) external;
    function ban(address user, bool status) external;

    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        bytes1[] calldata colors
    ) external payable;

    function isFrozen() external view returns (bool);

    function getTile(uint256 x, uint256 y) external view returns (
        bytes1 color,
        address author,
        uint32 layer,
        uint64 stamp
    );

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
