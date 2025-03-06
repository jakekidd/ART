// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

///////////////////
/// IART Interface
///////////////////

interface IART {
    event Update(
        uint256 indexed x,
        uint256 indexed y,
        uint80  value,
        uint16  author,
        uint32  layer,
        bytes16 link
    );

    event Frozen(uint256 finalDelta);
    event UserBlacklisted(uint16 userId);
    event UserReverted(uint16 userId);

    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        uint80[] calldata values,
        bytes16[] calldata prevLinks
    ) external;

    function rewind(
        uint16 target,
        uint256[] calldata xs,
        uint256[] calldata ys,
        bytes[] calldata history
    ) external;

    function freeze() external;
    function isFrozen() external view returns (bool);

    function getTile(uint256 x, uint256 y) external view returns (
        uint80 value,
        uint16 author,
        uint32 layer,
        bytes16 link
    );
    function getCanvas() external view returns (Tile[] memory);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
