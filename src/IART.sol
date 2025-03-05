// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

///////////////////
/// IART Interface
///////////////////

interface IART {
    event Update(
        uint256 indexed x,
        uint256 indexed y,
        uint24 value,
        uint16 author,
        uint32 layer,
        bytes20 prevLink
    );

    event Frozen(uint256 finalDelta);
    event UserBlacklisted(uint16 userId);
    event UserReverted(uint16 userId);

    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        uint24[] calldata values,
        bytes20[] calldata prevLinks
    ) external;

    function rewind(
        uint16 target,
        uint256[] calldata xs,
        uint256[] calldata ys,
        bytes[] calldata history
    ) external;

    function freeze() external;
    function isFrozen() external view returns (bool);

    function getUnit(uint256 x, uint256 y) external view returns (
        uint24 value,
        uint16 author,
        uint32 layer,
        bytes20 link
    );

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
