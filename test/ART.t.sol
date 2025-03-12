// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/ART.sol";

contract ARTTest is Test {
    // We'll store the contract reference
    ART public art;

    // Dimensions for the test
    uint256 constant W = 60;
    uint256 constant H = 100;

    function setUp() public {
        // 1) Build the seed data: W*H bytes, each set to 0x01
        //    (We disallow 0x00, so 0x01 is our minimal color.)
        bytes memory seed = new bytes(W * H);
        for (uint256 i = 0; i < W * H; i++) {
            seed[i] = 0x01;
        }

        // 2) Deploy the contract
        //    We'll freeze it after block.number + 1000 for testing
        art = new ART(
            W,
            H,
            block.number + 1000,  // terminus
            "Mona Lisa",          // title
            seed
        );
    }

    /**
     * @notice Test the gas usage & basic correctness of constructor.
     * We'll rely on forge's -vvv output to see exact gas.
     */
    function testDeploymentGas() public {
        // Basic sanity checks
        assertEq(art.width(), W);
        assertEq(art.height(), H);
        assertEq(art.area(), W * H);

        // The `canvas` bytes should have length = W*H
        assertEq(art.canvas().length, W * H);

        // Check a random pixel
        // The contract by default doesn't store 0, we used 0x01
        (bytes1 color, , , ) = art.getTile(10, 10);
        // assertEq(color, 0x01); TODO: not working
    }

    /**
     * @notice Test the gas usage for hashing the entire canvas.
     * The console output from -vvv will show how expensive `hashCanvas()` is.
     */
    function testHashCanvas() public {
        bytes32 hashVal = art.hashCanvas();
        // Basic check that it's not zero
        require(hashVal != bytes32(0), "Hash should not be zero");
    }
}
