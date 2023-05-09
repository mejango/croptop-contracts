// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "../src/CroptopPublisher.sol";

contract DeployMainnet is Script {
    function setUp() public {}

    function run() public {
        vm.broadcast();
    }
}

contract DeployGoerli is Script {
    // V3_1 goerli controller.
    IJBController3_1 _controller = IJBController3_1(0x1d260DE91233e650F136Bf35f8A4ea1F2b68aDB6);
    uint256 _feeProjectId = 1;
    address _owner = 0x823b92d6a4b2AED4b15675c7917c9f922ea8ADAD;

    function run() external {
        vm.startBroadcast();

        // Deploy the deployer.
        new CroptopPublisher(_controller, _feeProjectId, _owner);
    }
}
