# Hardhat 手动移植到 Foundry：逐步记录

本文按实际迁移过程记录命令和每一步产生的文件变化。迁移目标是在仓库根目录新增 `stake-contract-foundry/`，保留原来的 `stake-contract/` Hardhat 项目不动。

> 以下命令假设当前工作目录是仓库根目录。文中的 `/opt/homebrew/bin/solc` 是本次机器上的本地路径；其他机器请用 `command -v solc` 查询自己的路径。

## 第 1 步：确认迁移源和工具

查看原项目合约：

```bash
find stake-contract/contracts -maxdepth 1 -type f -print
```

本次复制的源文件：

- `stake-contract/contracts/MetaNode.sol`
- `stake-contract/contracts/MetaNodeStake.sol`
- `stake-contract/contracts/TestERC20.sol`

确认 Foundry 已安装：

```bash
forge --version
```

同时确认仓库中还没有目标目录，避免覆盖已有文件：

```bash
test ! -e stake-contract-foundry && echo "target directory does not exist"
```

## 第 2 步：创建 Foundry 目录结构并复制合约

执行：

```bash
mkdir -p stake-contract-foundry/contracts \
  stake-contract-foundry/test \
  stake-contract-foundry/script

cp stake-contract/contracts/MetaNode.sol \
  stake-contract/contracts/MetaNodeStake.sol \
  stake-contract/contracts/TestERC20.sol \
  stake-contract-foundry/contracts/
```

变化：

- 新建 `stake-contract-foundry/contracts/`、`test/` 和 `script/`。
- 把 MetaNode 奖励代币、质押主合约和测试 ERC20 复制到新的 `contracts/`。
- 原 Hardhat 目录保留原文件，之后对新目录的格式调整不会反向影响源目录。

## 第 3 步：创建 Foundry 配置和忽略规则

新建 `stake-contract-foundry/foundry.toml`：

```toml
[profile.default]
src = "contracts"
test = "test"
script = "script"
out = "out"
libs = ["lib"]
solc_version = "0.8.22"
optimizer = false
remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/"
]
```

配置含义：

- Solidity 合约源代码放 `contracts/`，测试放 `test/`，部署脚本放 `script/`。
- `out/` 是编译结果目录，`lib/` 放 Solidity 依赖。
- 编译器版本和优化器配置沿用原 Hardhat 项目设置。
- 两条 remapping 将合约中的 `@openzeppelin/...` 导入路径映射到 `lib/` 中的源码。

新建 `stake-contract-foundry/.gitignore`：

```gitignore
/cache
/out
/broadcast
```

这三项分别是 Foundry 的缓存、编译产物和广播交易记录目录，不作为手写源文件管理。

## 第 4 步：安装 OpenZeppelin 源码依赖

原合约分别导入 `@openzeppelin/contracts/...` 和 `@openzeppelin/contracts-upgradeable/...`。只安装普通 Contracts 包不够，还要有 Upgradeable 包。原 Hardhat `package.json` 使用 OpenZeppelin `5.0.2`，因此 Foundry 目录也放入同版本源码。

### 本次遇到的问题

首次在仓库根目录直接执行 `forge install` 时，Foundry 把仓库根目录识别为项目根，依赖被放到了根目录的 `lib/`，而不是 `stake-contract-foundry/lib/`。发现路径不对后，移除了这两个刚创建的根目录依赖目录，再改为把归档源码解压到新项目的 `lib/`。

手动下载和解压命令如下：

```bash
mkdir -p stake-contract-foundry/lib/openzeppelin-contracts \
  stake-contract-foundry/lib/openzeppelin-contracts-upgradeable

curl -fL -o /tmp/openzeppelin-contracts-v5.0.2.tar.gz \
  https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
tar -xzf /tmp/openzeppelin-contracts-v5.0.2.tar.gz \
  --strip-components=1 \
  -C stake-contract-foundry/lib/openzeppelin-contracts

curl -fL -o /tmp/openzeppelin-contracts-upgradeable-v5.0.2.tar.gz \
  https://codeload.github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/tar.gz/refs/tags/v5.0.2
tar -xzf /tmp/openzeppelin-contracts-upgradeable-v5.0.2.tar.gz \
  --strip-components=1 \
  -C stake-contract-foundry/lib/openzeppelin-contracts-upgradeable
```

`--strip-components=1` 用于去掉归档中最外层的版本目录，让 `contracts/` 直接位于各自的依赖目录下。解压后的关键文件应为：

```text
stake-contract-foundry/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol
stake-contract-foundry/lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol
```

检查文件和版本：

```bash
test -f stake-contract-foundry/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol
test -f stake-contract-foundry/lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol
grep -m1 '"version"' stake-contract-foundry/lib/openzeppelin-contracts/package.json
grep -m1 '"version"' stake-contract-foundry/lib/openzeppelin-contracts-upgradeable/package.json
```

临时归档在编译验证后清理：

```bash
rm -f /tmp/openzeppelin-contracts-v5.0.2.tar.gz \
  /tmp/openzeppelin-contracts-upgradeable-v5.0.2.tar.gz
```

## 第 5 步：把 Hardhat JavaScript 测试改写成 Solidity 测试

Hardhat 的 `test/01_MetaNodeStakeTest.js` 不能直接作为 Foundry 测试运行。Foundry 测试使用 Solidity 文件，并以 `.t.sol` 结尾。

新建 `stake-contract-foundry/test/MetaNodeStake.t.sol`，主要改写方式如下：

| Hardhat 测试方式 | Foundry 测试方式 |
|---|---|
| `ethers.getSigners()` | 测试合约中定义 Alice、Bob 等地址 |
| 连接 signer 后调用 | `vm.prank(user)` 设置下一次调用者 |
| 本地账户余额 | `vm.deal(user, amount)` 设置 ETH |
| `evm_mine` | `vm.roll(block.number + count)` 推进区块 |
| Chai `expect` | Solidity `require(condition, "reason")` |
| `upgrades.deployProxy(...)` | 部署实现合约和 `ERC1967Proxy`，把 `initialize` 编码作为代理构造参数 |

测试中的 `Vm` 是对 Foundry cheatcode 的最小接口声明，因此这个测试文件不需要额外导入 `forge-std`。

测试 `setUp()` 的步骤：

1. 部署 `MetaNodeToken` 作为奖励代币。
2. 部署 `MetaNodeStake` 实现合约。
3. 部署 `ERC1967Proxy`，在构造时调用 `initialize`。
4. 通过代理地址创建 `MetaNodeStake` 类型实例。
5. 添加 ETH 池，并向质押代理转入测试奖励代币。

覆盖的测试场景（共 32 项）：

- **初始化与权限**：初始化参数、重复初始化、管理员配置、升级角色和升级后状态。
- **质押与池配置**：ETH/ERC20 存款、授权和最低金额、池 ID、池添加约束、池参数及权重更新。
- **奖励记账**：新用户不获得入池前奖励、追加质押保留旧奖励、解质押保留已产生奖励、空池不累积奖励、领取奖励和奖励储备不足。
- **解质押与提现**：锁定期、零额和超额请求、请求列表状态、ETH/ERC20 转账及接收方失败回滚。
- **边界与异常**：奖励区块范围、无效区块区间、零权重、金额及奖励计算溢出、无效池 ID。
- **暂停功能**：暂停和恢复领奖、解质押及提现，并检查重复切换。

## 第 6 步：把部署和添加池脚本改成 Foundry Script

Foundry Script 使用 Solidity 编写，放在 `script/`，不继续使用 Hardhat JavaScript 和 `upgrades` 插件。

### `script/DeployMetaNodeStake.s.sol`

脚本读取以下环境变量：

- `META_NODE_TOKEN`：奖励代币地址。
- `START_BLOCK`：奖励开始区块。
- `END_BLOCK`：奖励结束区块。
- `META_NODE_PER_BLOCK`：每区块奖励量，使用代币最小单位。

执行步骤：

1. 部署 `MetaNodeStake` 实现合约。
2. 用 `abi.encodeCall` 编码 `initialize(...)`。
3. 部署 `ERC1967Proxy` 并在代理构造过程中执行初始化。
4. 返回代理地址对应的 `MetaNodeStake` 实例。

### `script/AddPool.s.sol`

脚本读取以下环境变量：

- `STAKE_PROXY`：质押代理地址。
- `STAKING_TOKEN`：池的质押代币地址；ETH 池使用零地址。
- `POOL_WEIGHT`：池权重。
- `MIN_DEPOSIT_AMOUNT`：最低存款额，使用代币最小单位。
- `UNSTAKE_LOCKED_BLOCKS`：解质押锁定区块数。
- `WITH_UPDATE`：调用 `addPool` 前是否更新已有池奖励。

两个脚本通过 `vm.startBroadcast()` 和 `vm.stopBroadcast()` 包围链上写操作。实际部署时用 RPC 参数和私钥启动脚本；不要把私钥写入脚本或提交到版本库。

## 第 7 步：编写使用说明

新建 `stake-contract-foundry/README.md`，记录依赖目录、编译、测试、代理部署、添加池及奖励代币资金准备事项。

需要注意：部署脚本只创建实现合约和代理，不会自动添加 ETH 池、添加 ERC20 池或转入奖励代币。部署后必须由有权限的管理员完成池配置，并为代理准备足够的奖励代币。

## 第 8 步：格式化、编译和测试

格式化新项目 Solidity 文件：

```bash
cd stake-contract-foundry
forge fmt
```

检查格式：

```bash
forge fmt --check
```

本机可用 `solc` 查询本地编译器路径：

```bash
command -v solc
solc --version
```

本次默认 `forge build` 尝试从网络下载配置的 `0.8.22` 编译器时遇到连接重置，因此使用本机安装的 `0.8.38` 完成验证：

```bash
forge build --use "$(command -v solc)"
forge test --use "$(command -v solc)" -vv
forge coverage --use "$(command -v solc)"
```

结果：

- `forge fmt --check` 通过。
- 本机 `solc 0.8.38` 编译成功；Foundry 配置目标仍为 `0.8.22`。
- `forge test`：32 项通过，0 项失败。
- `MetaNodeStake.sol` 覆盖率：行 100%（223/223）、语句 100%（223/223）、函数 100%（32/32）、分支 88.24%（90/102）。
- 覆盖率报告总计：行 91.54%（238/260）、语句 87.97%（234/266）、函数 95%（38/40）、分支 88.35%（91/103）。总计包含未在测试中执行的两个部署脚本，因此评估质押合约时应看 `MetaNodeStake.sol` 单独一行。
- 剩余未覆盖分支主要是 SafeMath `try*` 溢出检查的失败路径，以及 ETH 接收器返回数据的边界分支。
- 覆盖率测试辅助接收器会故意回滚或返回 `false`，编译时因此可能提示 fallback/receive 警告；这是测试模拟行为，不是生产合约新增警告。

Foundry 配置仍指定 `solc_version = "0.8.22"`，以保持与原项目一致。若网络可用，直接运行 `forge build` 和 `forge test -vv` 即可下载并使用配置版本；本地没有该版本时，可用 `--use` 临时指定本机兼容编译器。

## 第 9 步：检查迁移范围和工作区

迁移后检查文件：

```bash
find stake-contract-foundry -maxdepth 2 -type f -print | sort
git status --short
```

最终新项目大致结构：

```text
stake-contract-foundry/
├── .gitignore
├── README.md
├── MIGRATION.md
├── foundry.toml
├── contracts/
│   ├── MetaNode.sol
│   ├── MetaNodeStake.sol
│   └── TestERC20.sol
├── lib/
│   ├── openzeppelin-contracts/
│   └── openzeppelin-contracts-upgradeable/
├── script/
│   ├── AddPool.s.sol
│   └── DeployMetaNodeStake.s.sol
└── test/
    └── MetaNodeStake.t.sol
```

## 本次迁移的边界

- 原 Hardhat 项目保留，没有删除或替换。
- 合约业务逻辑没有为 Foundry 迁移而改写；执行 `forge fmt` 后，新目录中的 Solidity 代码格式可能与 Hardhat 源文件不同。
- Foundry 测试覆盖了主要业务行为，不是原 JavaScript 测试的逐行翻译。
- 其他 Hardhat 脚本、Ignition 部署历史、Etherscan 验证流程和前端未迁移。
- 本次验证编译器为本机 `0.8.38`，部署前应确认部署构建使用期望的 Solidity `0.8.22` 版本。
- 编译器对原合约 `_safeMetaNodeTransfer` 中未检查 `MetaNode.transfer` 返回值发出警告；此处属于原有逻辑，本次记录迁移时未修改。
