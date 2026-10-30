// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/MetaNodeStake.sol";

interface Vm {
    function envAddress(string calldata name) external returns (address);
    function envUint(string calldata name) external returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

contract DeployMetaNodeStake {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external returns (MetaNodeStake stake) {
        IERC20 rewardToken = IERC20(vm.envAddress("META_NODE_TOKEN"));
        uint256 startBlock = vm.envUint("START_BLOCK");
        uint256 endBlock = vm.envUint("END_BLOCK");
        uint256 rewardPerBlock = vm.envUint("META_NODE_PER_BLOCK");

        vm.startBroadcast();
        MetaNodeStake implementation = new MetaNodeStake();
        bytes memory initialization =
            abi.encodeCall(MetaNodeStake.initialize, (rewardToken, startBlock, endBlock, rewardPerBlock));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);
        stake = MetaNodeStake(payable(address(proxy)));
        vm.stopBroadcast();
    }
}
