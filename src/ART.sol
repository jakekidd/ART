// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC165} from "../lib/ERC165.sol";
import {IART} from "./IART.sol";

/**
ART: Artifact / Autonomous Repository Token
    - Has a 2D grid ("tiles") of size (width x height).
    - Each "Tile" is packed into exactly 32 bytes:
         value: 80 bits  (color/data)
         stamp: 64 bits  (block number when last edited)
         layer: 32 bits  (incremental edit counter)
         author: 160 bits (wallet address of last editor)
    - A global “delta” tallies net modifications across all tiles.
    - “terminus” is a block number after which the artifact is frozen (no edits).
    - “creator” sets config, initializes the ART, and receives tribute.
    - "owner" can edit after freeze to establish a final version of the ART. They pay no tribute for
    their edits.
    - “cred” tracks cumulative user contribution. A base amount is earned per edit, and an
    additional amount is farmed by how many blocks the author's tile survived before overwrite.
*/
// TODO: When frozen, do we need a way to payout creds to final authors, possibly with a bonus?

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
     *   - value: 80 bits (color/data)
     *   - stamp: 64 bits (block number when last edited)
     *   - layer: 32 bits (incremental edit counter)
     *   - author: 160 bits (wallet address of last editor)
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

    // ================ ROLES =================

    /** @notice The original deployer’s address, the collector of tribute. */
    address public immutable creator;

    /**
     * @notice The current owner. Can edit freely regardless of freeze, and print the final
     * version of the painting.
     */
    address public owner;

    // ================ STATS =================

    /** @notice The title of this artifact. */
    string public title;

    /** @notice Caption is separate from title, if needed. */
    string public caption;

        /** @notice The artifact’s width. */
    uint256 public immutable width;

    /** @notice The artifact’s height. */
    uint256 public immutable height;

    /** @notice The total area = width * height, provided for convenience. */
    uint256 public immutable area;

    /**
     * @notice The block number after which the painting is frozen.
     * Once block.number >= terminus, no further edits are allowed.
     */
    uint256 public immutable terminus;

    /** @notice Net modifications across all tiles, tracked for statistical purposes. */
    uint256 public delta;

    // TODO: We could use this as a reference block to zero the uint64 stamps for
    // compatibility with blockchains that might start at an insanely high block number
    // for some reason, but it seems largely unnecessary.
    // uint256 public immutable genesisBlock;

    // =============== TRIBUTE ================

    /** @notice The pool of tribute collected for contributions. */
    uint256 public tribute;

    /** @notice Base tribute cost per edit. */
    uint256 public constant BASE_TRIBUTE = 1000 gwei;

    /**
     * @notice Extra tribute cost per layer. This results in a linear increase in cost,
     * which produces a topography for the ART that 'locks in' contested tiles over time.
     */
    uint256 public constant TRIBUTE_PER_LAYER = 500 gwei;

    // ================= CRED =================

    /**
     * @notice cred mapping: address => total cred
     * Cred is awarded to tile authors based on how many blocks their tile survived,
     * plus a small base reward to the new editor.
     */
    mapping(address => uint256) public cred;
    uint256 public constant BASE_CRED = 10;

    // ================ STATE =================

    /**
     * @notice An evolving 2D grid of Tile data stored on-chain.
     */
    mapping(uint256 => mapping(uint256 => Tile)) public canvas;

    /** @notice Addresses that are banned from editing by the owner. */
    mapping(address => bool) public banned;

    // ============= CONSTRUCTOR ==============
    /**
     * @param _width The artifact’s width.
     * @param _height The artifact’s height.
     * @param _terminus Block number after which the ART is frozen and no further
     * edits are possible (except by the owner).
     * @param _title The string title of the artifact.
     */
    constructor(
        uint256 _width,
        uint256 _height,
        uint256 _terminus,
        string memory _title
        // TODO: TributeCollector contract + withdrawal method.
        // TODO: NFT integration for print() final version.
        // TODO: "seed" painting
    ) {
        creator = msg.sender;
        owner = msg.sender;

        width = _width;
        height = _height;
        area = _width * _height;

        terminus = _terminus;
        title = _title;

        // Pre-populate the entire canvas.
        // This will flatten storage update costs for future users.
        // WARNING: If NxM is huge, you may hit gas limit, and this will revert.
        // If it reverts, your ART is too big for this chain, and you must choose a smaller NxM.
        for (uint256 x = 0; x < _width; x++) {
            for (uint256 y = 0; y < _height; y++) {
                canvas[x][y] = Tile({
                    value: 0,
                    stamp: 0,
                    layer: 0,
                    author: address(0)
                });
            }
        }
    }

    // ============== MODIFIERS ===============

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier notFrozen() {
        if (isFrozen() && msg.sender != owner) {
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
    * @notice Transfers ownership of the contract to a new address.
    * @dev Can only be called by the current owner.
    * @param newOwner The address to transfer ownership to.
    */
    function transferOwnership(address newOwner) external override onlyOwner {
        require(newOwner != address(0), "Zero address");
        owner = newOwner;
    }

    /**
    * @notice Bans or restricts an address from making edits to the ART.
    * @dev Can only be called by the owner. Banned addresses cannot edit tiles.
    * @param user The address to be banned or unbanned.
    * @param status If true, the address is banned; if false, they are allowed to edit again.
    */
    function ban(address user, bool status) external override onlyOwner {
        banned[user] = status;
        if (status) {
            emit UserBanned(user);
        } else {
            emit UserRestored(user);
        }
    }

    // ================ FREEZE ================

    /**
    * @notice Checks whether the ART is currently frozen.
    * @return True if the block number has reached or exceeded the terminus, false otherwise.
    */
    function isFrozen() public view override returns (bool) {
        return block.number >= terminus;
    }


    // ================ EDIT ==================

    /**
    * @notice Edits multiple given tiles on the canvas.
    * - For each tile you change, you are awarded a base amount of cred.
    * - For each tile you change, you pay tribute, which linearly increases in cost per layer.
    * - The future cred you earn is based on how many blocks for which your tiles survive.
    *
    * @param xs The x-coordinates of the tiles to edit
    * @param ys The y-coordinates of the tiles to edit
    * @param newValues The new 80-bit values for each tile
    */
    function edit(
        uint256[] calldata xs,
        uint256[] calldata ys,
        uint80[] calldata newValues
    )
        external
        payable
        override
        notFrozen
        canEdit
    {
        uint256 n = xs.length;
        require(n == ys.length && n == newValues.length, "Array mismatch");

        // 1) Update each tile, awarding creds and collecting tribute.
        uint256 collectedCred;
        uint256 collectedTribute;
        bool tributeRequired = msg.sender != owner;
        uint64 blockNumber = uint64(block.number);
        for (uint256 i = 0; i < n; i++) {
            uint256 x = xs[i];
            uint256 y = ys[i];
            Tile memory oldTile = canvas[x][y];

            // All tiles are initially populated in constructor, if no author
            // is present, the tile must be invalid, i.e. out of bounds.
            if (oldTile.author == address(0)) {
                revert InvalidTile(x, y);
            }

            // Award cred to old author based on how long tile survived.
            uint256 survived = blockNumber - oldTile.stamp;
            cred[oldTile.author] += survived;

            // Collect initial cred to the reward the new author.
            collectedCred += BASE_CRED;

            // Overwrite tile with new data.
            uint32 newLayer = oldTile.layer + 1;
            canvas[x][y] = Tile({
                value: newValues[i],
                stamp: blockNumber,
                layer: newLayer,
                author: msg.sender
            });

            // Calculate tribute for this tile.
            if (tributeRequired) {
                collectedTribute += BASE_TRIBUTE + (oldTile.layer * TRIBUTE_PER_LAYER);
            }

            emit Update(x, y, newValues[i], msg.sender, newLayer);
        }

        // 2) Award the new author their collected cred.
        cred[msg.sender] += collectedCred;

        // 3) Collect tribute.
        if (tributeRequired) {
            uint256 amount = msg.value;
            // Check user paid sufficiently.
            if (amount < collectedTribute) {
                revert InsufficientTribute(amount, collectedTribute);
            }

            // If user overpaid, refund the difference as common courtesy.
            // TODO: need nonReentrant to do this. we may need it to allow people to overpay
            // to avoid race conditions (insufficient tribute because someone updated this tile
            // while transaction was in-flight).
            // uint256 refund = msg.value - totalFee;
            // if (refund > 0) {
            //     (bool success, ) = payable(msg.sender).call{value: refund}("");
            //     require(success, "Refund failed");
            // }
            tribute += amount;
        }

        // 4) Update delta.
        delta += n;

        // 5) Submit final event illustrating how many tiles were updated by this author.
        emit Edit(msg.sender, n);
    }

    // =========== VIEW FUNCTIONS =============

    /**
     * @notice Retrieves a single tile from on-chain storage.
     */
    function getTile(uint256 x, uint256 y)
        external
        view
        returns (
            uint80 value,
            uint64 stamp,
            uint32 layer,
            address author
        )
    {
        require(x < width && y < height, "Out of bounds");
        Tile memory t = canvas[x][y];
        return (t.value, t.stamp, t.layer, t.author);
    }

    /**
     * @notice Retrieves the entire NxM canvas in a single call. This is a gas-heavy
     * operation, meant for specialized RPC reads off-chain only.
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

    // =============== ERC165 =================

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC165, IART)
        returns (bool)
    {
        return interfaceId == type(IART).interfaceId || super.supportsInterface(interfaceId);
    }
}
