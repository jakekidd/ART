// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
ART: Artifact / Autonomous Repository Token
    - Has a 2D grid ("units") of size (width x height).
    - Each "unit" tracks { value, author, layer, link } in 29 bytes.
    - A global “delta” tallies net modifications across all units.
    - “omega” for auto-freeze if delta >= omega.
    - “creator” sets config, can freeze, can revert malicious edits.
    - “exclusive” means only creator can edit; otherwise open to all except blacklisted.
    - “cred” mapping tracks user’s cumulative contribution. 
      Earn cred on each edit, reduced by a linear decay function per unit: 
      award = max(0, BASE_CRED - layer * decay).

HINT:   Looping over a large area in the constructor can easily hit gas limits.
        This is a feature, not a bug. If the limitations of the chain are reached
        before initializing the art, you know your art is too big for this chain.
*/

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";

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

///////////////////
/// ART Contract
///////////////////

contract ART is ERC165, IART {
    // =========================
    //      STRUCTS
    // =========================

    /**
     * @notice Each unit on the artifact’s 2D grid.
     *  Occupies 29 bytes in a 32-byte slot (3 leftover bytes).
     *
     *  - value(3 bytes)
     *  - author(2 bytes)
     *  - layer(4 bytes)
     *  - link(20 bytes)
     */
    struct Unit {
        uint24 value;   // e.g. RGB color
        uint16 author;  // user ID
        uint32 layer;   // incremental edits count
        bytes20 link;   // previous state reference hash
    }

    // =========================
    //     STORAGE
    // =========================

    /** @notice The original deployer’s address. */
    address public immutable creator;

    /** @notice The current owner with exclusive privileges (can freeze, rewind, manage artists). */
    address public owner;

    /** @notice The artifact’s width. */
    uint256 public immutable width;

    /** @notice The artifact’s height. */
    uint256 public immutable height;

    /** @notice The total area = width * height. */
    uint256 public immutable area;

    /** @notice If delta >= omega => auto-freeze. 0 means no auto-freeze. */
    uint256 public immutable omega;

    /** @notice Whether the artifact is frozen. */
    bool public frozen;

    /** @notice Net modifications across all units. */
    uint256 public delta;

    /** @notice If true => only owner/artists can edit. If false => open to all except blacklisted. */
    bool public exclusive;

    /** @notice The linear decay factor for cred awarding. */
    uint256 public immutable decay;

    /** @notice The base cred for brand-new edits if oldEdits=0. */
    uint256 public constant BASE_CRED = 100;

    // (x, y) => Unit
    mapping(uint256 => mapping(uint256 => Unit)) public canvas;

    /** @notice user ID => total cred earned */
    mapping(uint16 => uint256) public cred;

    // =============== USER SYSTEM ===============

    /** @notice address => user ID (1..65535). 0 means unregistered. */
    mapping(address => uint16) public userToId;

    /** @notice user ID => address. */
    mapping(uint16 => address) public idToUser;

    /** @notice next user ID to assign. If we reach 65535, new users are blocked. */
    uint16 public nextUserId = 1;

    /** @notice blacklisted user IDs => malicious/no further edits. */
    mapping(uint16 => bool) public blacklisted;

    /** @notice set of addresses that can edit if exclusive=true. (owner is always allowed) */
    mapping(address => bool) public isArtist;

    // =============== CONSTRUCTOR ===============

    /**
     * @param _width The artifact’s width
     * @param _height The artifact’s height
     * @param _omega If delta >= omega => auto-freeze
     * @param _exclusive If true => only owner + artists can edit
     * @param _decay linear decay factor for cred awarding
     * @dev For demonstration, we attempt to seed the entire canvas, which might revert for large area.
     */
    constructor(
        uint256 _width,
        uint256 _height,
        uint256 _omega,
        bool _exclusive,
        uint256 _decay
    ) {
        creator = msg.sender; // purely informational
        owner = msg.sender;   // actual control

        width = _width;
        height = _height;
        area = _width * _height;
        omega = _omega;
        exclusive = _exclusive;
        decay = _decay;

        // Attempt to register the creator (userId=1)
        uint16 cId = _registerUser(msg.sender);

        // Pre-populate the entire canvas, setting default values.
        // WARNING: This can revert for too large area (if EVM gas limit reached).
        for (uint256 x = 0; x < _width; x++) {
            for (uint256 y = 0; y < _height; y++) {
                // store default unit. value=0, author=cId, layer=0, link=0.
                canvas[x][y] = Unit(0, cId, 0, bytes20(0));
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
     * @param newOwner The address that will own this contract.
     */
    function transfer(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero address invalid");
        owner = newOwner;
    }

    // =============== MODERATION: ARTISTS ===============

    /**
     * @notice Toggles or sets the exclusive mode.
     * @param _exclusive if true => only owner + artists can edit.
     */
    function setExclusive(bool _exclusive) external onlyOwner {
        exclusive = _exclusive;
    }

    /**
     * @notice Set or unset an address as an artist.
     * @param user the address to set
     * @param allowed whether user is an approved artist
     */
    function setArtist(address user, bool allowed) external onlyOwner {
        isArtist[user] = allowed;
    }

    // =============== CORE LOGIC: EDIT ===============

    /**
     * @notice Edits multiple units.
     * @dev If exclusive=true => only owner + isArtist can edit. Otherwise open to all except blacklisted.
     */
    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        uint24[] calldata values,
        bytes20[] calldata prevLinks
    ) external override notFrozen canEdit {
        // verify user
        uint16 userId = _registerUser(msg.sender);
        require(!blacklisted[userId], "User blacklisted");

        require(
            xs.length == ys.length && ys.length == values.length && values.length == prevLinks.length,
            "Array mismatch"
        );

        uint256 changes = 0;
        for (uint256 i = 0; i < xs.length; i++) {
            require(xs[i] < width && ys[i] < height, "Out of bounds");

            Unit storage u = canvas[xs[i]][ys[i]];
            uint32 oldEdits = u.layer;

            // set new state
            u.value = values[i];
            u.author = userId;
            u.layer = oldEdits + 1;
            u.link = prevLinks[i];

            // linear decay awarding cred
            uint256 decAmount = oldEdits * decay;
            uint256 award = 0;
            if (decAmount < BASE_CRED) {
                award = BASE_CRED - decAmount;
            }
            cred[userId] += award;

            changes++;
            emit Update(xs[i], ys[i], values[i], userId, u.layer, prevLinks[i]);
        }

        delta += changes;
        // auto-freeze if condition
        if (omega != 0 && delta >= omega) {
            frozen = true;
            emit Frozen(delta);
        }
    }

    // =============== MODERATION: REWIND ===============

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
            Unit storage top = canvas[xs[i]][ys[i]];
            if (top.author != target) {
                continue;
            }

            (bool found, Unit memory newState) = _findReplacement(top, target, history[i]);
            if (!found) {
                continue;
            }
            // revert to newState
            top.value = newState.value;
            top.author = newState.author;
            top.layer = newState.layer;
            top.link = newState.link;

            reverts++;
            emit Update(xs[i], ys[i], newState.value, newState.author, newState.layer, newState.link);
        }

        if (reverts > 0) {
            emit UserReverted(target);
        }
    }

    function _findReplacement(
        Unit storage top,
        uint16 target,
        bytes calldata encodedHistory
    ) internal view returns (bool, Unit memory) {
        uint256 recordSize = 29;
        uint256 totalLen = encodedHistory.length;
        if (totalLen % recordSize != 0) {
            return (false, Unit(0,0,0,bytes20(0)));
        }
        uint256 count = totalLen / recordSize;

        {
            bytes memory firstRec = _sliceBytes(encodedHistory, 0, recordSize);
            (uint24 val, uint16 aut, uint32 lay, bytes20 lk) = _decodeRecord(firstRec);
            if (lk != top.link || val != top.value || aut != top.author || lay != top.layer) {
                return (false, Unit(0,0,0,bytes20(0)));
            }
        }
        for (uint256 i = 1; i < count; i++) {
            bytes memory rec = _sliceBytes(encodedHistory, i*recordSize, recordSize);
            (uint24 v, uint16 a, uint32 l, bytes20 linkHash) = _decodeRecord(rec);
            if (a != target) {
                return (true, Unit(v,a,l,linkHash));
            }
        }
        return (false, Unit(0,0,0,bytes20(0)));
    }

    // =============== MODERATION: FREEZE ===============

    function freeze() external override {
        require(msg.sender == owner, "Not owner");
        frozen = true;
        emit Frozen(delta);
    }

    function isFrozen() external view override returns (bool) {
        return frozen;
    }


    // =============== VIEW ===============

    function getUnit(uint256 x, uint256 y)
        external
        view
        override
        returns (
            uint24 value,
            uint16 author,
            uint32 layer,
            bytes20 link
        )
    {
        require(x < width && y < height, "Out of bounds");
        Unit memory u = canvas[x][y];
        return (u.value, u.author, u.layer, u.link);
    }

    // =============== ERC165 ===============

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IART) returns (bool) {
        return
            interfaceId == type(IART).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // =============== INTERNAL UTILS ===============

    function _sliceBytes(bytes calldata data, uint256 start, uint256 length)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory temp = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            temp[i] = data[start + i];
        }
        return temp;
    }

    function _decodeRecord(bytes memory record)
        internal
        pure
        returns (uint24 val, uint16 aut, uint32 lay, bytes20 lk)
    {
        require(record.length == 29, "Invalid record size");

        val = (uint24(uint8(record[0])) << 16)
            | (uint24(uint8(record[1])) << 8)
            | uint24(uint8(record[2]));

        aut = (uint16(uint8(record[3])) << 8)
            | uint16(uint8(record[4]));

        lay = (uint32(uint8(record[5])) << 24)
            | (uint32(uint8(record[6])) << 16)
            | (uint32(uint8(record[7])) << 8)
            | uint32(uint8(record[8]));

        bytes32 linkSlot;
        assembly {
            linkSlot := mload(add(record, 0x20))
        }
        lk = bytes20(linkSlot << 96);
    }

    function _registerUser(address user) internal returns (uint16) {
        uint16 id = userToId[user];
        if (id == 0) {
            require(nextUserId < 65535, "Too many cooks");
            userToId[user] = nextUserId;
            idToUser[nextUserId] = user;
            nextUserId++;
        }
        return id;
    }
}
