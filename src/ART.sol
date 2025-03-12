// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC165} from "../lib/oz-erc165/ERC165.sol";
import {IART} from "./IART.sol";

/**
    ART: Artifact / Autonomous Repository Token
    - Has a 2D grid of size (width x height).
    - Each pixel's color is 1 byte, stored in `bytes canvas` (length = width*height).
    - Each pixel's metadata is stored in meta[y][x] => Info{ author, layer, stamp }.
    - "terminus" is the block number after which no edits are allowed by anyone (including owner).
    - "creator" is the original deployer and collects tribute fees.
    - "owner" can do certain administrative tasks, but pays tribute like everyone else, and cannot edit after freeze.
    - "banned" addresses cannot edit at all.
    - NOTE: We disallow color=0x00 to avoid emptying a storage slot (which can cause higher gas for future writes).
    - A "seed" painting is provided in the constructor to initialize the canvas.
*/
contract ART is ERC165, IART {
    // =========================
    //      STRUCTS
    // =========================

    /**
     * @notice Metadata for each pixel.
     *  - author: Who last edited this pixel.
     *  - layer: How many times overwritten.
     *  - stamp: Block number (uint64) of last edit.
     */
    struct Info {
        address author;
        uint32  layer;
        uint64  stamp;
    }

    // =========================
    //     IMMUTABLES
    // =========================

    /** @notice The original deployer’s address (tribute beneficiary). */
    address public immutable creator;

    /** @notice The artifact’s width. */
    uint256 public immutable width;

    /** @notice The artifact’s height. */
    uint256 public immutable height;

    /** @notice The total area = width * height. */
    uint256 public immutable area;

    /** @notice The block number after which no edits are possible. */
    uint256 public immutable terminus;

    // =========================
    //     STATE VARS
    // =========================

    /** @notice The current owner (no special editing privileges after freeze). */
    address public owner;

    /** @notice The title of this artifact. */
    string public title;

    /** @notice Caption is separate from title, if needed. */
    string public caption;

    /** @notice Net modifications across all pixels, for statistics. */
    uint256 public delta;

    /**
     * @notice Single bytes array for pixel data: length = width * height.
     * Each pixel is 1 byte => canvas[y*width + x].
     */
    bytes public canvas;

    /**
     * @notice 2D mapping for metadata. meta[y][x] => Info (author, layer, stamp).
     */
    mapping(uint256 => mapping(uint256 => Info)) public meta;

    /** @notice Accumulated tribute fees in this contract. */
    uint256 public tribute;

    /** @notice Base tribute cost per pixel edit. */
    uint256 public constant BASE_TRIBUTE = 1000 gwei;

    /** @notice Extra cost per pixel layer. */
    uint256 public constant TRIBUTE_PER_LAYER = 500 gwei;

    /** @notice cred mapping for user addresses. */
    mapping(address => uint256) public cred;

    /** @notice A small base cred for new authors each edit. */
    uint256 public constant BASE_CRED = 10;

    /** @notice Addresses banned from editing. */
    mapping(address => bool) public banned;

    // ============= CONSTRUCTOR =============
    /**
     * @param _width     The artifact’s width.
     * @param _height    The artifact’s height.
     * @param _terminus  Block number after which the painting is frozen.
     * @param _title     The string title of the artifact.
     * @param _seed      The initial seed painting data. Must be length == _width*_height.
     *                   (Should not contain 0x00 for any pixel, and use 0x01 as zero value.)
     * TODO: Need to connect fee taker contract and NFT contract for final print.
     */
    constructor(
        uint256 _width,
        uint256 _height,
        uint256 _terminus,
        string memory _title,
        bytes memory _seed
    ) {
        creator = msg.sender;
        owner = msg.sender;

        width = _width;
        height = _height;
        area = _width * _height;
        terminus = _terminus;
        title = _title;

        // 1) Check seed length
        if (_seed.length != area) {
            revert InvalidSeedLength();
        }

        // 2) TODO: Verify no zero bytes in _seed... but need more efficient method.
        // for (uint256 i = 0; i < area; i++) {
        //     if (_seed[i] == 0x00) {
        //         revert SeedContainsZero();
        //     }
        // }

        // 3) Initialize canvas with _seed
        canvas = _seed;

        // 4) TODO: Currently no forced metadata init => all meta[] defaults to (author=0, layer=0, stamp=0).
        //    The first actual edit sets real author data.
    }

    // ============== MODIFIERS ===============

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert NotOwner();
        }
        _;
    }

    modifier notFrozen() {
        if (isFrozen()) {
            revert Frozen();
        }
        _;
    }

    modifier canEdit() {
        if (banned[msg.sender]) {
            revert Banned();
        }
        _;
    }

    // ================ ADMIN =================

    /**
     * @notice Transfers ownership to a new address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        owner = newOwner;
    }

    /**
     * @notice Bans or unbans an address from editing.
     */
    function ban(address user, bool status) external onlyOwner {
        banned[user] = status;
        if (status) {
            emit UserBanned(user);
        } else {
            emit UserRestored(user);
        }
    }

    // ================ EDIT ==================
    /**
     * @notice Edits multiple pixels on the canvas. 
     * For each pixel:
     *   - We disallow color=0 (ColorZeroNotAllowed).
     *   - We collect tribute = BASE_TRIBUTE + (layer * TRIBUTE_PER_LAYER).
     *   - We award old author => (block.number - oldTile.stamp) cred.
     *   - We award the new author => BASE_CRED total (summed up for this transaction).
     *   - We update the metadata in `meta[y][x]`.
     *
     * Attempting to edit a pixel if its metadata is all default => means it's never been edited,
     * so the first real edit sets that tile's author/layer/stamp properly.
     *
     * @param xs        X-coordinates of changed pixels
     * @param ys        Y-coordinates of changed pixels
     * @param colors    The new 1-byte color for each pixel
     */
    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        bytes1[] calldata colors
    )
        external
        payable
        override
        notFrozen
        canEdit
    {
        uint256 n = xs.length;
        if (n != ys.length || n != colors.length) {
            revert ArrayMismatch();
        }

        uint64 blockNow = uint64(block.number);
        uint256 totalTribute = 0;
        uint256 totalCredAward = 0;

        // TODO: We use a minimal approach: set each pixel individually.
        // For advanced optimization, we could group by storage slot, and
        // update in batches to reduce redundant reads.

        for (uint256 i = 0; i < n; i++) {
            uint256 x = xs[i];
            uint256 y = ys[i];
            if (x >= width || y >= height) {
                revert InvalidPixel(x, y);
            }
            bytes1 c = colors[i];
            if (c == 0x00) {
                revert ColorZeroNotAllowed();
            }

            // 1) Find the old metadata
            Info memory info = meta[y][x];
            // old color
            uint256 idx = (y * width) + x;
            // bytes1 oldColor = canvas[idx];

            // 2) Award cred to previous author.
            if (info.author != address(0)) {
                uint256 survived = blockNow - info.stamp;
                cred[info.author] += survived;
            }

            // 3) Add base cred for new author.
            totalCredAward += BASE_CRED;

            // 4) Tally tribute cost.
            uint256 cost = BASE_TRIBUTE + (info.layer * TRIBUTE_PER_LAYER);
            totalTribute += cost;

            // 5) Overwrite color in canvas.
            _setPixel(idx, c);

            // 6) Update metadata.
            meta[y][x] = Info(
                msg.sender,
                info.layer + 1,
                blockNow
            );

            emit Update(x, y, c, msg.sender, info.layer);
        }

        // 7) Check fee paid.
        // TODO: refund the diff if overpaid, but would need nonReentrant.
        if (msg.value < totalTribute) {
            revert InsufficientTribute(msg.value, totalTribute);
        }
        tribute += msg.value;

        // 8) Increase cred for the new editor.
        cred[msg.sender] += totalCredAward;

        // 9) Bump delta.
        delta += n;

        // 10) Fire an event summarizing.
        emit Edit(msg.sender, n);
    }

    // =============== INTERNAL ===============
    /**
     * @dev `_setPixel` does minimal assembly to set a single byte in `canvas`.
     * We do a single sload/sstore for the relevant slot. 
     * For more advanced usage, consider `_setPixelBatch`.
     */
    function _setPixel(uint256 index, bytes1 color) internal {
        // direct approach: no zero, so we skip zero-check here, done above
        assembly {
            // storage slot of the 'canvas' dynamic array:
            //   - canvas.slot is where length is stored
            //   - array contents are at keccak256(canvas.slot) in memory

            // 1) pointer to the storage of canvas contents
            let slot := canvas.slot
            // 2) offset for data
            // First slot is array length, so actual data starts at keccak256(slot) offset
            // We use the standard free pointer method for dynamic arrays:
            // compute base pointer of canvas data
            // keccak256(slot) => starting offset
            mstore(0x00, slot)
            let base := keccak256(0x00, 0x20)

            // 3) which slot of 32 bytes we're editing
            let byteSlot := add(base, div(index, 32))
            // 4) offset in that slot
            let offset := mod(index, 32)

            // 5) sload the existing 32 bytes
            let stored := sload(byteSlot)

            // 6) zero out that byte, then or in the new color
            let shift := mul(offset, 8)   // offset in bits
            let mask := shl(shift, 0xFF) // which byte to clear

            // clear that byte
            stored := and(stored, not(mask))
            // insert color
            let shiftedColor := shl(shift, color)
            stored := or(stored, shiftedColor)

            // 7) sstore final
            sstore(byteSlot, stored)
        }
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Checks whether the ART is currently frozen (no edits allowed).
     * @return True if block.number >= terminus, false otherwise.
     */
    function isFrozen() public view override returns (bool) {
        return block.number >= terminus;
    }

    /**
     * @notice Get a single pixel’s color + metadata in one call.
     */
    function getTile(uint256 x, uint256 y)
        external
        view
        override
        returns (
            bytes1 color,
            address author,
            uint32 layer,
            uint64 stamp
        )
    {
        require(x < width && y < height, "Out of bounds");
        uint256 idx = (y * width) + x;
        color = canvas[idx];
        Info memory i = meta[y][x];
        return (color, i.author, i.layer, i.stamp);
    }

    /**
     * @notice Hash the entire `canvas` array in one go.
     * Typically used if you want on-chain version hashing (off-chain viewers).
     */
    function hashCanvas() external view returns (bytes32) {
        return keccak256(abi.encodePacked(canvas));
    }

    /**
     * @notice Return the entire `canvas` as a single bytes array (gas-heavy).
     * For custom usage by off-chain indexing or display.
     */
    function getCanvas() external view returns (bytes memory) {
        return canvas;
    }

    /**
     * @notice Return all metadata in row-major order (extremely gas-heavy for large NxM).
     */
    function getAllMeta() external view returns (Info[] memory) {
        Info[] memory all = new Info[](area);
        uint256 idx = 0;
        for (uint256 y = 0; y < height; y++) {
            for (uint256 x = 0; x < width; x++) {
                all[idx] = meta[y][x];
                idx++;
            }
        }
        return all;
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
}
