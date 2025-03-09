// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

///////////////////
/// IART Interface
///////////////////

interface IART {
    event Update(uint256 x, uint256 y, uint80 value, address author, uint32 layer);
    event Edit(address indexed editor, uint256 indexed numChanges);
    event UserBanned(address indexed user);
    event UserRestored(address indexed user);

    error InvalidTile(uint256 x, uint256 y); 
    error InsufficientTribute(uint256 given, uint256 needed);
    error Frozen();
    error Banned();

    function transferOwnership(address newOwner) external;
    function ban(address user, bool status) external;

    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        uint80[] calldata newValues
    ) external payable;

    function isFrozen() external view returns (bool);

    function getTile(uint256 x, uint256 y) external view returns (
        uint80 value,
        uint64 stamp,
        uint32 layer,
        address author
    );

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
