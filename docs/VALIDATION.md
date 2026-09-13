# Validation record

Executed September 13, 2026 with Foundry v1.4.3, Solidity 0.8.26, optimizer 200 runs, legacy compiler pipeline and Cancun EVM.

## Final result

**27 checks passed, 0 failed, 0 skipped**, with the optional Robinhood fork enabled. The local-only command runs 26 checks and skips the explicit fork test. Machine-readable local output is saved in `artifacts/test-results.json`; rerun the command below to regenerate it.

```sh
ROBINHOOD_FORK_RPC=https://rpc.mainnet.chain.robinhood.com \
ROBINHOOD_FORK_BLOCK=62023274 \
forge test --json > artifacts/test-results.json
forge fmt --check
forge build --sizes
forge script script/LocalDemo.s.sol:LocalDemo -vv
```

The fork pins Robinhood mainnet chain ID `4663`, block `62,023,274`, and PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`. It executes successful buys and a profitable full sell against the actual manager bytecode. Its quote token and inverse market exist only in the simulation.

| Suite | Checks | Evidence |
|---|---:|---|
| `InverseMarketTest` | 10 | Whitepaper result; fees; decimal normalization; payout differential; atomic slippage/allowance rollback; donations; index bounds; exact full exit; native-price/chart counterexample |
| `InverseSecurityTest` | 8 | Bypass and exact-output router rejection; native liquidity/donation rejection; nested unlock; unfunded claims; initialization restrictions; callback authorization; frozen-index observation; reentrancy and taxed/surcharged quote rollback; unrelated manager quote preservation |
| `InverseTokenTest` | 6 | Share-transfer conservation; independent share/nominal allowances; rounding; token and full-share exits; signed-delta supply bound; repeated tiny round trips |
| `InverseInvariantTest` | 2 | Account shares/cash and reserves exactly match an independent integer AMM; share conservation; mark equivalence; no unsettled deltas/inventory; deterministic post-unlock index |
| `RobinhoodForkTest` | 1 | Canonical deployed manager buy/buy/sell sequence |

The three fuzz tests ran 512 generated cases each (the differential test also replayed one saved case, totaling 513). The two stateful invariants each ran **128 sequences × 64 calls = 8,192 calls**, with **zero unexpected reverts**. Handler actions include buys, partial/full-share sales and transfers among four holders, with a 0.30% input fee. The separate payout differential varies immutable fees from 0–10%. These are bounded tests, not a proof over all possible states or fee configurations.

The whitepaper scenario returns `118.032786` six-decimal quote units to Alice after two 100-unit buys and her full exit. Her exact shares clear to zero. After the two buys the inverse spot prices are approximately `0.826446281` and `0.694444444`; after her sale, `0.854224058`.

## Deployment and size checks

Both `DeployInverse` and `InitializeInverse` were broadcast successfully to a disposable **local Anvil chain (31337)** using an Anvil development account and mock quote. CREATE2 prediction matched the deployed hook, the initial index was `1e27`, and initialization committed the configured 1,000/1,000 share/quote seed. Logs are saved in `artifacts/local-deploy.txt` and `artifacts/local-initialize.txt`. These addresses and transactions are local test records, not public deployments.

| Contract | Runtime bytes | Creation bytes, excluding constructor arguments |
|---|---:|---:|
| InverseToken | 3,659 | 4,230 |
| InverseGateway | 7,571 | 7,930 |
| InverseHook | 13,152 | 28,290 |

All production contracts fit EIP-170 runtime and EIP-3860 creation-size limits. The hook's creation bytecode includes creation of its token and gateway. Foundry scripts and test harnesses are not production contracts.

## Full deployment workflow follow-up

The new `scripts/deploy.py` workflow and Solidity deployment/verifier scripts were tested end to end with `python3 scripts/test_deployment.py` on a disposable Anvil chain. The checks passed for insufficient-seed preflight; full deployment/initialization dry-run with no transactions; three-transaction deployment with real mock quote liquidity and archived receipts; independent network-state verification; repeated runs with no extra transactions or funding; a live buy and subsequent verification; recovery after deployment plus approval using only one initialization transaction; unseeded-state verification rejection; wrong-chain rejection; and existing-configuration mismatch rejection. The test manages and stops its own local node. Output is saved in `artifacts/full-deployment-tests.txt`.

The contract regression suite was rerun after these script changes: **26 passed, 0 failed**, with the opt-in Robinhood fork test skipped because its RPC variable was not enabled for this follow-up. The earlier successful pinned Robinhood fork result above still applies to the unchanged production contracts. Solidity formatting and Python compilation checks passed. `scripts/test_deployment.py` is now included in CI.

## Remaining external validation

No public chain transaction, funded public market, selected production quote, source verification, DEX Screener/Fomo integration, external application P&L reconciliation or independent security audit has been completed. The fork proves manager interoperability, not application support or universal asset compatibility. Liquidity is permanently locked by this MVP's explicit policy. See [integration gates](INTEGRATION.md) and [accounting constraints](ARCHITECTURE.md).
