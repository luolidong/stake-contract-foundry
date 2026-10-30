# MetaNodeStake Foundry

This is the Foundry version of the contracts. The original Hardhat project remains in `../stake-contract`.

OpenZeppelin Contracts and Contracts Upgradeable v5.0.2 are included in `lib/`.
The configured compiler is Solidity 0.8.22.

## Build and test

```bash
forge build
forge test -vv
```

If Foundry cannot download solc because of network restrictions, use an installed compatible compiler:

```bash
forge build --use "$(command -v solc)"
forge test --use "$(command -v solc)" -vv
forge coverage --use "$(command -v solc)"
```

Current `MetaNodeStake.sol` test coverage: 100% lines/statements/functions and 88.24% branches (32 tests). Foundry also includes deployment scripts in the overall coverage total; use the per-file `MetaNodeStake.sol` row when assessing contract coverage.

## Deploy

Set `META_NODE_TOKEN`, `START_BLOCK`, `END_BLOCK`, and `META_NODE_PER_BLOCK` in the environment, then run:

```bash
forge script script/DeployMetaNodeStake.s.sol:DeployMetaNodeStake \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

The script deploys the implementation and an ERC1967 proxy initialized with the supplied parameters. It does not create a pool or fund reward tokens; configure pools and transfer MetaNode tokens to the proxy separately.

To add an ETH pool, set `STAKING_TOKEN` to the zero address. For an ERC20 pool, set it to the staking token address. Set `STAKE_PROXY`, `POOL_WEIGHT`, `MIN_DEPOSIT_AMOUNT`, `UNSTAKE_LOCKED_BLOCKS`, and `WITH_UPDATE`, then run:

```bash
forge script script/AddPool.s.sol:AddPool \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```
