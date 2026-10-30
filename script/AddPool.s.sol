// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/MetaNodeStake.sol";

interface Vm {
    function envAddress(string calldata name) external returns (address);
    function envUint(string calldata name) external returns (uint256);
    function envBool(string calldata name) external returns (bool);
    function startBroadcast() external;
    function stopBroadcast() external;
}

contract AddPool {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function run() external {
        MetaNodeStake stake = MetaNodeStake(payable(vm.envAddress("STAKE_PROXY")));
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        uint256 poolWeight = vm.envUint("POOL_WEIGHT");
        uint256 minDepositAmount = vm.envUint("MIN_DEPOSIT_AMOUNT");
        uint256 unstakeLockedBlocks = vm.envUint("UNSTAKE_LOCKED_BLOCKS");
        bool withUpdate = vm.envBool("WITH_UPDATE");

        vm.startBroadcast();
        stake.addPool(stakingToken, poolWeight, minDepositAmount, unstakeLockedBlocks, withUpdate);
        vm.stopBroadcast();
    }
}
