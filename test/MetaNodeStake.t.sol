// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../contracts/MetaNode.sol";
import "../contracts/MetaNodeStake.sol";
import "../contracts/TestERC20.sol";

interface Vm {
    function deal(address account, uint256 balance) external;
    function expectRevert() external;
    function prank(address sender) external;
    function roll(uint256 newHeight) external;
}

// 模拟提现时回滚或返回 false 的 ETH 接收方。
contract FalseReturningEthReceiver {
    MetaNodeStake private immutable stake;
    bool private immutable shouldReturnFalse;

    constructor(MetaNodeStake stake_, bool shouldReturnFalse_) {
        stake = stake_;
        shouldReturnFalse = shouldReturnFalse_;
    }

    function depositAndUnstake(uint256 amount) external payable {
        stake.depositETH{value: msg.value}();
        stake.unstake(0, amount);
    }

    function withdraw() external {
        stake.withdraw(0);
    }

    fallback(bytes calldata) external payable returns (bytes memory) {
        if (!shouldReturnFalse) revert("reject ETH");
        return abi.encode(false);
    }
}

contract MetaNodeStakeTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MetaNodeToken private rewardToken;
    MetaNodeStake private stake;
    address private constant alice = address(0xA11CE);
    address private constant bob = address(0xB0B);
    uint256 private constant unstakeLockedBlocks = 10;

    // 每个测试部署独立代理、ETH 池，并预存奖励代币。
    function setUp() public {
        rewardToken = new MetaNodeToken();
        MetaNodeStake implementation = new MetaNodeStake();
        uint256 start = block.number;
        bytes memory initialization =
            abi.encodeCall(MetaNodeStake.initialize, (rewardToken, start, start + 1_000, 1 ether));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);
        stake = MetaNodeStake(payable(address(proxy)));
        stake.addPool(address(0), 1, 0, unstakeLockedBlocks, false);
        require(rewardToken.transfer(address(stake), 1_000_000 ether), "reward funding failed");
    }

    // ETH 存入后，用户余额和池总质押量应同步增加。
    function testDepositETHUpdatesBalances() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        stake.depositETH{value: 3 ether}();

        require(stake.stakingBalance(0, alice) == 3 ether, "user stake mismatch");
        (,,,, uint256 poolAmount,,) = stake.pool(0);
        require(poolAmount == 3 ether, "pool stake mismatch");
    }

    // 新用户入池后不能分得其入池前产生的奖励。
    function testNewDepositorDoesNotReceiveEarlierRewards() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();

        vm.roll(block.number + 10);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        stake.depositETH{value: 1 ether}();

        require(stake.pendingMetaNode(0, alice) == 10 ether, "earlier reward missing");
        require(stake.pendingMetaNode(0, bob) == 0, "new depositor received earlier reward");
    }

    // 已累计的奖励领取后转给用户，待领奖励归零。
    function testClaimTransfersAccruedRewards() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();

        vm.roll(block.number + 10);
        vm.prank(alice);
        stake.claim(0);

        require(rewardToken.balanceOf(alice) == 10 ether, "reward transfer mismatch");
        require(stake.pendingMetaNode(0, alice) == 0, "reward was not cleared");
    }

    // 解质押请求未解锁时不能提现，达到区块高度后才能取回 ETH。
    function testWithdrawRequiresUnstakeLock() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        stake.depositETH{value: 3 ether}();

        vm.prank(alice);
        stake.unstake(0, 1 ether);

        vm.prank(alice);
        stake.withdraw(0);
        require(address(alice).balance == 7 ether, "locked funds withdrawn early");

        vm.roll(block.number + unstakeLockedBlocks);
        vm.prank(alice);
        stake.withdraw(0);
        require(address(alice).balance == 8 ether, "unlocked funds not withdrawn");
    }

    // 非管理员不能更换奖励代币地址。
    function testOnlyAdminCanChangeMetaNode() public {
        vm.prank(alice);
        vm.expectRevert();
        stake.setMetaNode(rewardToken);
    }

    // ERC20 授权后可存入对应池，并正确记录用户份额。
    function testERC20PoolDeposit() public {
        TestERC20 stakingToken = new TestERC20("Stake Token", "STK", 100 ether);
        stake.addPool(address(stakingToken), 1, 0, unstakeLockedBlocks, false);
        require(stakingToken.transfer(alice, 5 ether), "staking token transfer failed");

        vm.prank(alice);
        stakingToken.approve(address(stake), 5 ether);
        vm.prank(alice);
        stake.deposit(1, 5 ether);

        require(stake.stakingBalance(1, alice) == 5 ether, "ERC20 stake mismatch");
    }

    // 初始化参数必须有效，代理初始化后不能再次初始化。
    function testInitializeRejectsInvalidParametersAndSecondInitialization() public {
        MetaNodeStake implementation = new MetaNodeStake();
        vm.expectRevert();
        implementation.initialize(rewardToken, 2, 1, 1);

        vm.expectRevert();
        implementation.initialize(rewardToken, 1, 2, 0);

        uint256 start = stake.startBlock();
        uint256 end = stake.endBlock();
        vm.expectRevert();
        stake.initialize(rewardToken, start, end, 1 ether);
    }

    // 管理员可更新奖励区间和速率，非法参数及非管理员调用会回滚。
    function testAdminParameterUpdatesAndValidation() public {
        uint256 oldStart = stake.startBlock();
        uint256 oldEnd = stake.endBlock();

        stake.setStartBlock(oldStart + 1);
        require(stake.startBlock() == oldStart + 1, "start block not updated");
        vm.expectRevert();
        stake.setStartBlock(oldEnd + 1);

        stake.setEndBlock(oldEnd + 1);
        require(stake.endBlock() == oldEnd + 1, "end block not updated");
        vm.expectRevert();
        stake.setEndBlock(oldStart);

        stake.setMetaNodePerBlock(2 ether);
        require(stake.MetaNodePerBlock() == 2 ether, "reward rate not updated");
        vm.expectRevert();
        stake.setMetaNodePerBlock(0);

        vm.prank(alice);
        vm.expectRevert();
        stake.setStartBlock(oldStart);
    }

    // 验证领奖、解质押和提现的暂停开关及重复切换限制。
    function testPauseAndUnpauseClaimAndWithdraw() public {
        stake.pauseClaim();
        require(stake.claimPaused(), "claim should be paused");
        vm.expectRevert();
        stake.pauseClaim();
        vm.prank(alice);
        vm.expectRevert();
        stake.claim(0);
        stake.unpauseClaim();
        require(!stake.claimPaused(), "claim should be unpaused");
        vm.expectRevert();
        stake.unpauseClaim();

        stake.pauseWithdraw();
        require(stake.withdrawPaused(), "withdraw should be paused");
        vm.expectRevert();
        stake.pauseWithdraw();
        vm.prank(alice);
        vm.expectRevert();
        stake.unstake(0, 0);
        vm.prank(alice);
        vm.expectRevert();
        stake.withdraw(0);
        stake.unpauseWithdraw();
        require(!stake.withdrawPaused(), "withdraw should be unpaused");
        vm.expectRevert();
        stake.unpauseWithdraw();
    }

    // 验证添加池、更新池配置和调整权重的权限与状态变化。
    function testPoolAdminFunctionsValidateInputsAndUpdateState() public {
        vm.prank(alice);
        vm.expectRevert();
        stake.addPool(address(0), 1, 0, unstakeLockedBlocks, false);

        vm.expectRevert();
        stake.addPool(address(1), 1, 0, 0, false);

        vm.expectRevert();
        stake.addPool(address(0), 1, 0, unstakeLockedBlocks, false);

        TestERC20 token = new TestERC20("Pool Token", "POOL", 100 ether);
        stake.addPool(address(token), 3, 1 ether, unstakeLockedBlocks, true);
        require(stake.poolLength() == 2, "pool was not added");
        require(stake.totalPoolWeight() == 4, "pool weight total mismatch");

        stake.updatePool(1, 2 ether, 20);
        (,,,,, uint256 minimum, uint256 lockBlocks) = stake.pool(1);
        require(minimum == 2 ether && lockBlocks == 20, "pool config mismatch");

        vm.prank(alice);
        vm.expectRevert();
        stake.updatePool(1, 0, 1);
        vm.expectRevert();
        stake.updatePool(2, 0, 1);

        vm.expectRevert();
        stake.setPoolWeight(1, 0, false);
        stake.setPoolWeight(1, 5, true);
        require(stake.totalPoolWeight() == 6, "pool weight total not updated");
        (, uint256 updatedWeight,,,,,) = stake.pool(1);
        require(updatedWeight == 5, "pool weight not updated");
    }

    // 首池必须是 ETH 池，且所有池的解质押锁定区块数必须非零。
    function testAddPoolRequiresFirstETHPoolAndNonzeroLock() public {
        MetaNodeStake isolated = _deployStakeWithoutPool();
        vm.expectRevert();
        isolated.addPool(address(1), 1, 0, unstakeLockedBlocks, false);
        vm.expectRevert();
        isolated.addPool(address(0), 1, 0, 0, false);
    }

    // 奖励结束区块到达后不能再添加新池。
    function testAddPoolCannotBeCalledAfterEndBlock() public {
        vm.roll(stake.endBlock());
        vm.expectRevert();
        stake.addPool(address(1), 1, 0, unstakeLockedBlocks, false);
    }

    // 验证 ETH/ERC20 池类型、池 ID、最低存款额和 ERC20 授权检查。
    function testDepositETHAndERC20ValidatePoolAndMinimum() public {
        vm.expectRevert();
        stake.deposit(0, 1 ether);

        stake.updatePool(0, 1 ether, unstakeLockedBlocks);
        vm.expectRevert();
        stake.depositETH{value: 0}();

        vm.expectRevert();
        stake.stakingBalance(1, alice);

        TestERC20 token = new TestERC20("Pool Token", "POOL", 100 ether);
        stake.addPool(address(token), 1, 1 ether, unstakeLockedBlocks, false);
        token.transfer(alice, 5 ether);

        vm.prank(alice);
        vm.expectRevert();
        stake.deposit(1, 1 ether);

        vm.prank(alice);
        vm.expectRevert();
        stake.deposit(2, 2 ether);

        vm.prank(alice);
        vm.expectRevert();
        stake.deposit(1, 2 ether);

        vm.prank(alice);
        token.approve(address(stake), 5 ether);
        vm.prank(alice);
        vm.expectRevert();
        stake.deposit(1, 6 ether);
    }

    // 覆盖超额解质押、零额请求、未解锁查询及请求移除路径。
    function testUnstakeAndWithdrawBranches() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert();
        stake.unstake(0, 2 ether);

        vm.prank(alice);
        stake.unstake(0, 0);
        (uint256 requested, uint256 withdrawable) = stake.withdrawAmount(0, alice);
        require(requested == 0 && withdrawable == 0, "zero unstake added request");

        vm.prank(alice);
        stake.unstake(0, 1 ether);
        (requested, withdrawable) = stake.withdrawAmount(0, alice);
        require(requested == 1 ether && withdrawable == 0, "locked request mismatch");

        vm.prank(alice);
        stake.withdraw(0);
        vm.roll(block.number + unstakeLockedBlocks);
        (requested, withdrawable) = stake.withdrawAmount(0, alice);
        require(requested == 1 ether && withdrawable == 1 ether, "unlocked request mismatch");

        vm.prank(alice);
        stake.withdraw(0);
        (requested, withdrawable) = stake.withdrawAmount(0, alice);
        require(requested == 0 && withdrawable == 0, "withdraw request not removed");
    }

    // 发起解质押时，已产生但未领取的奖励仍保留在用户账本。
    function testUnstakeAccumulatesAlreadyEarnedReward() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();

        vm.roll(block.number + 5);
        vm.prank(alice);
        stake.unstake(0, 0);

        (,, uint256 savedPending) = stake.user(0, alice);
        require(savedPending == 5 ether, "unstake did not preserve earned rewards");
        require(stake.pendingMetaNode(0, alice) == 5 ether, "pending reward mismatch");
    }

    // ERC20 解质押解锁后应将本金转回用户。
    function testERC20UnstakeAndWithdraw() public {
        TestERC20 token = new TestERC20("Pool Token", "POOL", 10 ether);
        stake.addPool(address(token), 1, 0, unstakeLockedBlocks, false);
        token.transfer(alice, 2 ether);
        vm.prank(alice);
        token.approve(address(stake), 2 ether);
        vm.prank(alice);
        stake.deposit(1, 2 ether);
        vm.prank(alice);
        stake.unstake(1, 1 ether);

        vm.roll(block.number + unstakeLockedBlocks);
        vm.prank(alice);
        stake.withdraw(1);
        require(token.balanceOf(alice) == 1 ether, "ERC20 withdrawal mismatch");
    }

    // 奖励储备不足时，实际转账不超过合约余额且账面待领奖励清零。
    function testClaimCapsRewardAtAvailableTokenBalance() public {
        stake.setMetaNodePerBlock(2_000_000 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();

        vm.roll(block.number + 1);
        vm.prank(alice);
        stake.claim(0);

        require(rewardToken.balanceOf(alice) == 1_000_000 ether, "claim did not cap transfer");
        require(rewardToken.balanceOf(address(stake)) == 0, "reward reserve should be empty");
        require(stake.pendingMetaNode(0, alice) == 0, "claim did not clear pending reward");
    }

    // ETH 接收方返回 false 时提现回滚，解质押请求保持不变。
    function testWithdrawRejectsReceiverReturningFalse() public {
        FalseReturningEthReceiver receiver = new FalseReturningEthReceiver(stake, true);
        vm.deal(address(this), 1 ether);
        vm.deal(address(receiver), 1 ether);
        receiver.depositAndUnstake{value: 1 ether}(1 ether);

        vm.roll(block.number + unstakeLockedBlocks);
        vm.expectRevert();
        receiver.withdraw();

        (uint256 requested, uint256 withdrawable) = stake.withdrawAmount(0, address(receiver));
        require(requested == 1 ether && withdrawable == 1 ether, "failed withdrawal changed request");
    }

    // ETH 接收方回滚时提现也应回滚。
    function testWithdrawRejectsReceiverReverting() public {
        FalseReturningEthReceiver receiver = new FalseReturningEthReceiver(stake, false);
        vm.deal(address(this), 1 ether);
        vm.deal(address(receiver), 1 ether);
        receiver.depositAndUnstake{value: 1 ether}(1 ether);

        vm.roll(block.number + unstakeLockedBlocks);
        vm.expectRevert();
        receiver.withdraw();
    }

    // 无奖励时可正常调用领奖；所有查询和操作都拒绝无效池 ID。
    function testClaimWithoutRewardAndInvalidPool() public {
        vm.prank(alice);
        stake.claim(0);
        vm.expectRevert();
        stake.claim(1);
        vm.expectRevert();
        stake.pendingMetaNode(1, alice);
        vm.expectRevert();
        stake.pendingMetaNodeByBlockNumber(1, alice, block.number);
        vm.expectRevert();
        stake.withdrawAmount(1, alice);
    }

    // 奖励区间会裁剪到 startBlock/endBlock，非法区间会回滚。
    function testGetMultiplierClampsStartAndEndAndRejectsInvalidRange() public {
        uint256 start = stake.startBlock();
        uint256 end = stake.endBlock();
        require(stake.getMultiplier(start - 1, start + 2) == 2 ether, "start clamp mismatch");
        require(stake.getMultiplier(end - 2, end + 10) == 2 ether, "end clamp mismatch");
        vm.expectRevert();
        stake.getMultiplier(start + 1, start);
        vm.expectRevert();
        stake.getMultiplier(end + 1, end + 2);
    }

    // 区块奖励乘法溢出时 getMultiplier 应回滚。
    function testGetMultiplierRejectsOverflow() public {
        stake.setMetaNodePerBlock(type(uint256).max);
        uint256 start = stake.startBlock();
        vm.expectRevert();
        stake.getMultiplier(start, start + 2);
    }

    // 空池更新只推进记账区块，不把空池期间奖励分给后来用户。
    function testUpdatePoolWithEmptySupplyAndMassUpdate() public {
        (,, uint256 lastBefore,,,,) = stake.pool(0);
        stake.updatePool(0);
        (,, uint256 lastAfterNoop,,,,) = stake.pool(0);
        require(lastAfterNoop == lastBefore, "same-block update changed block");

        vm.roll(block.number + 5);
        stake.massUpdatePools();
        (,, uint256 lastAfterUpdate, uint256 accAfterUpdate,,,) = stake.pool(0);
        require(lastAfterUpdate == block.number, "pool block not updated");
        require(accAfterUpdate == 0, "empty pool received rewards");

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();
        require(stake.pendingMetaNode(0, alice) == 0, "empty-pool rewards were allocated");
    }

    // 验证待领奖励的预测值、池更新及追加质押时旧奖励的保留。
    function testPendingRewardAndPoolUpdateBranches() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();

        vm.roll(block.number + 5);
        uint256 pending = stake.pendingMetaNodeByBlockNumber(0, alice, block.number);
        require(pending == 5 ether, "projected pending reward mismatch");

        stake.updatePool(0);
        (,, uint256 updatedAt, uint256 accumulated,,,) = stake.pool(0);
        require(updatedAt == block.number && accumulated == 5 ether, "pool reward update mismatch");

        vm.prank(alice);
        stake.depositETH{value: 1 ether}();
        require(stake.pendingMetaNode(0, alice) == 5 ether, "deposit did not preserve old reward");

        vm.roll(stake.endBlock() + 1);
        require(
            stake.pendingMetaNodeByBlockNumber(0, alice, stake.endBlock()) >= 5 ether, "end-block reward query failed"
        );
    }

    // 非管理员或无效池 ID 不能修改池权重。
    function testSetPoolWeightRejectsInvalidPoolAndNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        stake.setPoolWeight(0, 2, false);
        vm.expectRevert();
        stake.setPoolWeight(1, 2, false);
    }

    // 管理员可以更换奖励代币合约地址。
    function testSetMetaNodeAdminCanUpdateAddress() public {
        TestERC20 replacement = new TestERC20("Reward", "RWD", 1 ether);
        stake.setMetaNode(replacement);
        require(address(stake.MetaNode()) == address(replacement), "reward token not changed");
    }

    // 两种重载的 updatePool 都必须拒绝无效池 ID。
    function testUpdatePoolRejectsInvalidPid() public {
        vm.expectRevert();
        stake.updatePool(1);
        vm.expectRevert();
        stake.updatePool(1, 0, 1);
    }

    // 总池权重为零时无法计算池奖励，更新应回滚。
    function testUpdatePoolRejectsZeroTotalWeight() public {
        MetaNodeStake isolated = _deployStakeWithoutPool();
        isolated.addPool(address(0), 0, 0, unstakeLockedBlocks, false);
        vm.roll(block.number + 1);
        vm.expectRevert();
        isolated.updatePool(0);
    }

    // 计算池权重奖励时发生乘法溢出应回滚。
    function testUpdatePoolRejectsRewardMultiplicationOverflow() public {
        stake.setMetaNodePerBlock(type(uint256).max / 2);
        stake.setPoolWeight(0, 3, false);
        vm.roll(block.number + 2);
        vm.expectRevert();
        stake.updatePool(0);
    }

    // 奖励乘以精度系数溢出时，更新池奖励应回滚。
    function testUpdatePoolRejectsPrecisionMultiplicationOverflow() public {
        stake.setMetaNodePerBlock(type(uint256).max / 2);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        stake.depositETH{value: 1 ether}();
        vm.roll(block.number + 1);
        vm.expectRevert();
        stake.updatePool(0);
    }

    // 用户质押额或池总质押额发生 uint256 溢出时存款应回滚。
    function testDepositRejectsUserAndPoolAmountOverflow() public {
        vm.deal(alice, type(uint256).max);
        vm.prank(alice);
        stake.depositETH{value: type(uint256).max}();

        vm.deal(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        stake.depositETH{value: 1}();

        vm.deal(bob, 1);
        vm.prank(bob);
        vm.expectRevert();
        stake.depositETH{value: 1}();
    }

    // 无升级角色者不能升级；持有 UPGRADE_ROLE 的初始化账户可以升级。
    function testUpgradeRequiresUpgradeRoleAndAdminCanUpgrade() public {
        MetaNodeStake nextImplementation = new MetaNodeStake();
        vm.prank(alice);
        vm.expectRevert();
        stake.upgradeToAndCall(address(nextImplementation), "");

        stake.upgradeToAndCall(address(nextImplementation), "");
        require(stake.poolLength() == 1, "proxy state lost after upgrade");
    }

    // 创建尚未添加池的独立代理，用于首池和零总权重边界测试。
    function _deployStakeWithoutPool() private returns (MetaNodeStake isolated) {
        MetaNodeStake implementation = new MetaNodeStake();
        bytes memory initialization =
            abi.encodeCall(MetaNodeStake.initialize, (rewardToken, block.number, block.number + 100, 1 ether));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initialization);
        isolated = MetaNodeStake(payable(address(proxy)));
    }
}
