// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC165} from "../lib/ERC165.sol";
import {IART} from "./IART.sol";

/**
ART: Artifact / Autonomous Repository Token
    - Has a 2D grid ("tiles") of size (width x height).
    - Each "Tile" is packed into exactly 32 bytes:
         link:   16 bytes (128 bits)
         value:  10 bytes (80 bits)
         layer:   4 bytes (32 bits)
         author:  2 bytes (16 bits)
    - A global “delta” tallies net modifications across all tiles.
    - “omega” for auto-freeze if delta >= omega.
    - “creator” sets config, can freeze, can revert malicious edits.
    - “exclusive” means only creator can edit; otherwise open to all except blacklisted.
    - “cred” tracks cumulative user contribution. Award = max(0, BASE_CRED - layer*decay).
*/

///////////////////
/// ART Contract
///////////////////

contract ART is ERC165, IART {
    // =========================
    //      STRUCTS
    // =========================

    /**
     * @notice Each tile is exactly 32 bytes (256 bits).
     *  Breakdown:
     *   - value:      80 bits  (color/data)
     *   - stamp:      64 bits  (block number when last edited)
     *   - layer:      32 bits  (incremental edit counter)
     *   - author:     160 bits (wallet address of last editor)
     */
    struct Tile {
        uint80 value;
        uint64 stamp;
        uint32 layer;
        address author;
    }


    // =========================
    //     STORAGE
    // =========================

    /** @notice The title of this artifact. */
    string public title;

    /** @notice Caption is separate from title, if needed. */
    string public caption;

    /** @notice The original deployer’s address (informational). */
    address public immutable creator;

    /** @notice The current owner (can freeze, rewind, manage artists). */
    address public owner;

    /** @notice The artifact’s width. */
    uint256 public immutable width;

    /** @notice The artifact’s height. */
    uint256 public immutable height;

    /** @notice The total area = width * height. */
    uint256 public immutable area;

    /** @notice If delta >= omega => auto-freeze (0 => no auto-freeze). */
    uint256 public immutable omega;

    /** @notice Whether the artifact is frozen. */
    bool public frozen;

    /** @notice Net modifications across all tiles. */
    uint256 public delta;

    /** @notice If true => only owner/artists can edit. Otherwise open except blacklisted. */
    bool public exclusive;

    /** @notice The linear decay factor for cred awarding. */
    uint256 public immutable decay;

    /** @notice The base cred for a brand-new edit (layer=0). */
    uint256 public constant BASE_CRED = 100;

    // (x, y) => Tile
    mapping(uint256 => mapping(uint256 => Tile)) public canvas;

    /** @notice user ID => total cred earned. */
    mapping(uint16 => uint256) public cred;

    // =============== USER SYSTEM ===============
    /** @notice blacklisted user IDs => no further edits. */
    mapping(uint16 => bool) public blacklisted;
    /** @notice allowed artists if exclusive=true. (owner is always allowed) */
    mapping(address => bool) public isArtist;

    // =============== CONSTRUCTOR ===============

    /**
     * @param _width The artifact’s width
     * @param _height The artifact’s height
     * @param _omega If delta >= omega => auto-freeze
     * @param _decay linear decay factor for cred awarding
     * @param _exclusive If true => only owner + artists can edit
     * @param _title The string title of the artifact
     */
    constructor(
        uint256 _width,
        uint256 _height,
        uint256 _omega,
        uint256 _decay,
        bool _exclusive,
        string memory _title
    ) {
        creator = msg.sender; // purely informational
        owner = msg.sender;   // actual control

        width = _width;
        height = _height;
        area = _width * _height;
        omega = _omega;
        exclusive = _exclusive;
        decay = _decay;
        title = _title;

        // Attempt to register the creator (userId=1)
        uint16 cId = _registerUser(msg.sender);

        // Pre-populate the entire canvas. May revert if area is too large for gas.
        for (uint256 x = 0; x < _width; x++) {
            for (uint256 y = 0; y < _height; y++) {
                // Default tile: link=0, value=0, layer=0, author=cId
                canvas[x][y] = Tile(bytes16(0), 0, 0, cId);
            }
        }
    }

    // =============== MODIFIERS ===============

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier notFrozen() {
        require(!frozen, "Artifact is frozen");
        _;
    }

    modifier canEdit() {
        if (exclusive && !isArtist[msg.sender] && msg.sender != owner) {
            revert("Editing not allowed");
        }
        _;
    }

    // =============== TOKEN LOGIC ===============

    /**
     * @notice Transfer ownership to a new address.
     */
    function transfer(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address invalid");
        owner = newOwner;
    }

    // =============== MODERATION: ARTISTS ===============

    /**
     * @notice Toggles or sets exclusive mode. If true => only owner + artists can edit.
     */
    function setExclusive(bool _exclusive) external onlyOwner {
        exclusive = _exclusive;
    }

    /**
     * @notice Set or unset an address as an artist (allowed to edit if exclusive=true).
     */
    function setArtist(address user, bool allowed) external onlyOwner {
        isArtist[user] = allowed;
    }

    // =============== CORE LOGIC: EDIT ===============

    /**
     * @notice Edits the painting and records a new Merkle root for history.
     *
     * @param newRoot The Merkle root after applying the edit (computed off-chain).
     * @param xs The x-coordinates of changed tiles.
     * @param ys The y-coordinates of changed tiles.
     * @param values The new values for each tile.
     */
    function edit(
        bytes32 newRoot,
        uint256[] calldata xs,
        uint256[] calldata ys,
        uint80[] calldata values
    )
        external
        notFrozen
        canEdit
    {
        uint256 numChanges = xs.length;
        require(xs.length == ys.length && ys.length == values.length, "Array length mismatch");

        // Process each tile edit
        for (uint256 i = 0; i < numChanges; i++) {
            uint256 x = xs[i];
            uint256 y = ys[i];

            Tile storage oldTile = canvas[x][y];

            // Award cred to the previous tile author
            uint256 blocksSurvived = block.number - oldTile.blockStamp;
            cred[oldTile.author] += blocksSurvived;

            // Update tile with new values and new author
            canvas[x][y] = Tile({
                value: values[i],
                blockStamp: uint64(block.number),
                layer: oldTile.layer + 1,
                author: msg.sender
            });

            emit Update(x, y, values[i], msg.sender, oldTile.layer + 1);
        }

        // Increment global delta
        delta += numChanges;
        if (omega != 0 && delta >= omega) {
            frozen = true;
            emit Frozen(delta);
        }

        // Store new Merkle root for history tracking
        currentRoot = newRoot;
        editions[newRoot] = true;

        emit EditMade(msg.sender, numChanges, newRoot);
    }


    /**
     * @notice Edits multiple tiles. 
     * @dev If exclusive=true => only owner + isArtist can edit; else all except blacklisted.
     * @param xs The x-coordinates of the tiles to edit
     * @param ys The y-coordinates of the tiles to edit
     * @param values The new value (80 bits) for each tile
     * @param prevLinks The new link (16 bytes) for each tile
     */
    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        uint80[] calldata values,
        bytes16[] calldata prevLinks
    ) external override notFrozen canEdit {
        // register user if needed
        uint16 userId = _registerUser(msg.sender);
        require(!blacklisted[userId], "User blacklisted");

        require(
            xs.length == ys.length &&
            ys.length == values.length &&
            values.length == prevLinks.length,
            "Array mismatch"
        );

        uint256 changes = 0;
        for (uint256 i = 0; i < xs.length; i++) {
            require(xs[i] < width && ys[i] < height, "Out of bounds");

            Tile storage t = canvas[xs[i]][ys[i]];
            uint32 oldEdits = t.layer;

            // update tile
            t.link = prevLinks[i];
            t.value = values[i];
            t.layer = oldEdits + 1;
            t.author = userId;

            // linear decay awarding cred
            uint256 decAmount = oldEdits * decay;
            uint256 award = 0;
            if (decAmount < BASE_CRED) {
                award = BASE_CRED - decAmount;
            }
            cred[userId] += award;

            changes++;
            emit Update(xs[i], ys[i], t.value, t.author, t.layer, t.link);
        }

        delta += changes;
        // auto-freeze if condition
        if (omega != 0 && delta >= omega) {
            frozen = true;
            emit Frozen(delta);
        }
    }

    // =============== MODERATION: REWIND ===============

    /**
     * @notice Blacklist a user and revert their edits using an off-chain "history" record.
     * @param target The user ID to blacklist
     * @param xs The x-coordinates to attempt rewinding
     * @param ys The y-coordinates to attempt rewinding
     * @param history A sequence of 32-byte records (concatenated) for each tile.
     *                Each record stores { link(16b), value(80b), layer(32b), author(16b) }
     *                from newest to older states.
     */
    function rewind(
        uint16 target,
        uint256[] calldata xs,
        uint256[] calldata ys,
        bytes[] calldata history
    ) external override onlyOwner {
        require(xs.length == ys.length && ys.length == history.length, "Array mismatch");

        blacklisted[target] = true;
        emit UserBlacklisted(target);

        uint256 reverts = 0;
        for (uint256 i = 0; i < xs.length; i++) {
            require(xs[i] < width && ys[i] < height, "Out of bounds");
            Tile storage top = canvas[xs[i]][ys[i]];
            if (top.author != target) {
                continue; // tile not by the blacklisted user
            }

            (bool found, Tile memory newState) = _findReplacement(top, target, history[i]);
            if (!found) {
                continue;
            }
            // revert to newState
            top.link = newState.link;
            top.value = newState.value;
            top.layer = newState.layer;
            top.author = newState.author;

            reverts++;
            emit Update(xs[i], ys[i], top.value, top.author, top.layer, top.link);
        }

        if (reverts > 0) {
            emit UserReverted(target);
        }
    }

    /**
     * @dev Internal function to scan a tile's concatenated history,
     *      searching for the first older record whose `author != target`.
     */
    function _findReplacement(
        Tile storage top,
        uint16 target,
        bytes calldata encodedHistory
    ) internal view returns (bool, Tile memory) {
        // each record is exactly 32 bytes: link(16b) + value(10b) + layer(4b) + author(2b)
        uint256 recordSize = 32;
        uint256 totalLen = encodedHistory.length;
        if (totalLen % recordSize != 0) {
            return (false, Tile(bytes16(0), 0, 0, 0));
        }
        uint256 count = totalLen / recordSize;

        // 1) The first record in `encodedHistory` must match the current tile
        {
            bytes memory firstRec = _sliceBytes(encodedHistory, 0, recordSize);
            (bytes16 lk, uint80 val, uint32 lay, uint16 aut) = _decodeRecord(firstRec);
            // If it doesn't match the on-chain tile, there's an integrity mismatch
            if (
                lk != top.link ||
                val != top.value ||
                lay != top.layer ||
                aut != top.author
            ) {
                return (false, Tile(bytes16(0), 0, 0, 0));
            }
        }

        // 2) Scan older records (index=1..count-1), looking for the first with different author
        for (uint256 i = 1; i < count; i++) {
            bytes memory rec = _sliceBytes(encodedHistory, i * recordSize, recordSize);
            (bytes16 lk2, uint80 val2, uint32 lay2, uint16 aut2) = _decodeRecord(rec);

            if (aut2 != target) {
                // Found a prior state not authored by `target`. Rewind to that.
                return (true, Tile(lk2, val2, lay2, aut2));
            }
        }

        // No older record belongs to someone else => can't revert
        return (false, Tile(bytes16(0), 0, 0, 0));
    }

    // =============== MODERATION: FREEZE ===============

    function freeze() external override onlyOwner {
        frozen = true;
        emit Frozen(delta);
    }

    function isFrozen() external view override returns (bool) {
        return frozen;
    }

    // =============== VIEW FUNCTIONS ===============

    /**
     * @notice Retrieves the details of a specific tile.
     */
    function getTile(uint256 x, uint256 y)
        external
        view
        override
        returns (
            uint80  value,
            uint16  author,
            uint32  layer,
            bytes16 link
        )
    {
        require(x < width && y < height, "Out of bounds");
        Tile memory t = canvas[x][y];
        return (t.value, t.author, t.layer, t.link);
    }

    /**
     * @notice Retrieves the entire canvas in a single call (gas-heavy).
     */
    function getCanvas() external view returns (Tile[] memory) {
        Tile[] memory tiles = new Tile[](area);
        uint256 index = 0;
        for (uint256 y = 0; y < height; y++) {
            for (uint256 x = 0; x < width; x++) {
                tiles[index] = canvas[x][y];
                index++;
            }
        }
        return tiles;
    }

    // =============== ERC165 ===============

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IART)
        returns (bool)
    {
        return interfaceId == type(IART).interfaceId || super.supportsInterface(interfaceId);
    }

    // =============== INTERNAL UTILS ===============

    /**
     * @dev Extracts a slice from `data[start .. start+length-1]` into a new bytes array.
     */
    function _sliceBytes(
        bytes calldata data,
        uint256 start,
        uint256 length
    ) internal pure returns (bytes memory) {
        bytes memory temp = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            temp[i] = data[start + i];
        }
        return temp;
    }

    /**
     * @dev Decodes a 32-byte record: {link(16b), value(80b), layer(32b), author(16b)}.
     */
    function _decodeRecord(bytes memory record)
        internal
        pure
        returns (bytes16 lk, uint80 val, uint32 lay, uint16 aut)
    {
        require(record.length == 32, "Invalid record size");

        // 1) link (first 16 bytes)
        bytes memory linkPart = _sliceBytes(record, 0, 16);
        assembly {
            lk := mload(add(linkPart, 0x20))
        }

        // 2) value (next 10 bytes => 80 bits)
        bytes memory valuePart = _sliceBytes(record, 16, 10);
        uint128 tmpVal;
        assembly {
            tmpVal := mload(add(valuePart, 0x20))
        }
        // shift right by (128 - 80) = 48 to move top 80 bits into lower bits
        val = uint80(tmpVal >> 48);

        // 3) layer (next 4 bytes => 32 bits)
        bytes memory layerPart = _sliceBytes(record, 26, 4);
        uint32 tmpLay;
        assembly {
            tmpLay := mload(add(layerPart, 0x20))
        }
        // shift out the unused (256 - 32 = 224)
        lay = uint32(tmpLay >> 224);

        // 4) author (last 2 bytes => 16 bits)
        bytes memory authorPart = _sliceBytes(record, 30, 2);
        uint256 tmpAut;
        assembly {
            tmpAut := mload(add(authorPart, 0x20))
        }
        // shift out the unused (256 - 16 = 240)
        aut = uint16(tmpAut >> 240);

        return (lk, val, lay, aut);
    }

    /**
     * @dev Register a user address => user ID if not already registered.
     */
    function _registerUser(address user) internal returns (uint16) {
        uint16 id = userToId[user];
        if (id == 0) {
            require(nextUserId < 65535, "Too many cooks");
            userToId[user] = nextUserId;
            idToUser[nextUserId] = user;
            id = nextUserId;
            nextUserId++;
        }
        return id;
    }
}
