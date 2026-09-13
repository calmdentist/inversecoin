# Inverse Token

A Solidity/Foundry implementation of the [whitepaper](inverse_price_token_whitepaper.md): a fixed-share token, a Uniswap v4 custom-accounting hook/vault, and an atomic trading gateway. Buys increase the share price and displayed balances while lowering the marginal price per displayed token. Sells reverse that movement. Quote proceeds match an ordinary constant-product market with the same shares, inputs, and fee.

**Status: working contract prototype.** Local integration, differential, invariant, and Robinhood mainnet fork tests pass. **Inverted charts on DEX Screener/Fomo and Fomo routing/P&L are not validated.** Native v4 swap price fields do not track this custom curve. A contract deployment alone does not meet those application requirements. See [integration gates](docs/INTEGRATION.md).

## Run

Requires Git, Python 3, and Foundry (`forge`, `cast`, `anvil`); tested with Foundry v1.4.3 and Solidity 0.8.26 (Cancun EVM). Solidity dependencies are installed by the bootstrap script; the Python scripts use the standard library.

```sh
git clone https://github.com/calmdentist/inversecoin.git
cd inversecoin
bash scripts/bootstrap.sh
forge build
forge test
forge script script/LocalDemo.s.sol:LocalDemo -vv
```

Dependencies are pinned by commit in [dependencies.lock.json](dependencies.lock.json). The installer also retrieves the dependencies' pinned submodules. `lib/` is ignored. Compiler settings use the legacy pipeline; the IR pipeline triggered a solc 0.8.26 internal compiler error on this source.

The demo needs no wallet, RPC, or funds. With 1,000 shares and 1,000 six-decimal quote units at zero fees:

| Action | Inverse spot price | Alice displayed tokens | Alice quote flow |
|---|---:|---:|---:|
| Initial | 1.000000 | 0 | 0 |
| Alice buys 100 | 0.826446 | 133.100000 | -100 |
| Bob buys 100 | 0.694444 | 188.509091 | 0 |
| Alice sells all shares | 0.854224 | 0 | +118.032786 |

The result is one raw quote unit below the whitepaper's rounded display of 118.032787, and less than one raw quote unit below the exact value. Gas and application fees are excluded.

## Contracts

| Contract | Responsibility |
|---|---|
| [InverseToken](src/InverseToken.sol) | Fixed shares, rebased ERC-20 views, share approvals/transfers, restricted v4 settlement inventory |
| [InverseHook](src/InverseHook.sol) | Permanent seed reserves, constant-product pricing, canonical-pool enforcement, deterministic index, quotes and finalized events |
| [InverseGateway](src/InverseGateway.sol) | Exact-input buys/sells, deadlines, share/quote slippage, v4 unlock and settlement, post-unlock finalization |
| [InverseMath](src/libraries/InverseMath.sol) | Full-precision reserve calculations, rounding, index and signed-delta bounds |

`InverseHook` creates its own token and gateway, binding all three immutably. The hook address must have v4 permission bits `0x2aa8`; the deployment script mines a CREATE2 salt.

**Liquidity policy:** all shares begin in the vault. The designated seeder deposits the configured quote amount once. Seed liquidity and retained fees are permanently locked; there are no LP tokens, additional liquidity methods, owner withdrawals, upgrades, fee setters, or additional share issuance. Unsolicited donations are excluded from accounted reserves and cannot be recovered. Choose seed amounts before deploying.

The quote must be a standard, non-rebasing ERC-20 with 6–18 decimals. No native ETH, taxed transfers, sender surcharges, or unsupported token callbacks are part of the supported asset model. A dollar chart additionally assumes the quote is worth one dollar; the contracts compute quote-denominated prices.

## Trade API

All shares and displayed tokens use 18 decimals. Quote amounts use the quote asset's native decimals. Prices and the index use `1e27` precision.

```solidity
// Read a bounded quote immediately before constructing a transaction.
IInverseMarket.Trade memory buyQuote = hook.preview(true, quoteIn);

quoteToken.approve(address(gateway), quoteIn);
gateway.buy(quoteIn, minSharesOut, recipient, deadline);

// Stable share allowance, distinct from the ERC-20 allowance.
token.approveShares(address(gateway), sharesIn);
gateway.sellShares(sharesIn, minQuoteOut, recipient, deadline);

// Convert tokens at the committed index when execution starts, or exit all shares.
gateway.sellTokens(tokensIn, minQuoteOut, recipient, deadline);
gateway.sellAll(minQuoteOut, recipient, deadline);
```

`minSharesOut` measures ownership, so a changing denomination cannot defeat slippage protection. `sellAll` is the precise full-exit path; converting a floored `balanceOf` back to shares can leave a remainder. All sell paths require `approveShares`. The gateway spends only the calling account's funds. Applications can invoke it from the user's smart account; arbitrary relayers cannot name an unrelated payer.

`sharePriceRay()`, `tokenPriceRay()`, `spotValue(account)`, `sharesOf(account)`, `indexRay()`, and the finalized `EconomicSwap`/`ReservesUpdated` events support reconciliation. `spotValue` is an 18-decimal quote mark before exit impact/fees, not a guaranteed liquidation amount. No on-chain cost-basis ledger is claimed. See [accounting and integration](docs/INTEGRATION.md).

## Robinhood Chain

Official network configuration lists mainnet `4663` and testnet `46630`. Uniswap's mainnet PoolManager is `0x8366a39CC670B4001A1121B8F6A443A643e40951`. Sources checked September 13, 2026: [Robinhood network documentation](https://docs.robinhood.com/chain/connecting/), [Uniswap v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments).

Run against the deployed PoolManager on a read-only fork:

```sh
ROBINHOOD_FORK_RPC=https://rpc.mainnet.chain.robinhood.com \
ROBINHOOD_FORK_BLOCK=62023274 \
forge test --match-contract RobinhoodForkTest -vv
```

The test creates a mock quote and this market only inside the fork. It does not broadcast anything or validate a specific live stablecoin. Without `ROBINHOOD_FORK_RPC`, this optional test reports **skipped**. The default suite uses the pinned, real v4 PoolManager implementation locally.

Deployment steps and tested evidence: [DEPLOYMENT.md](docs/DEPLOYMENT.md), [VALIDATION.md](docs/VALIDATION.md). No public-network deployment has been performed and no public liquidity has been funded.

## Deploy contracts and seed liquidity together

Copy `.env.example` to `.env`, then set `DEPLOYER`, `QUOTE_TOKEN`, the chain/manager, initial share supply, quote seed amount, and immutable fee. The deployer needs that quote balance and native ETH for gas.

```sh
# Simulate the complete deployment and initialization.
python3 scripts/deploy.py --rpc-url robinhood

# Deploy, approve quote, seed the vault, initialize the v4 pool, and verify network state.
python3 scripts/deploy.py --rpc-url robinhood --account YOUR_KEYSTORE --broadcast
```

The driver writes a timestamped record under `artifacts/deployments/` containing the contract addresses, pool ID, reserves, settings, network verification and public transaction receipts. A dry-run report is clearly marked as a simulation. Rerunning the same configuration reuses the deployed market and finishes any missing initialization; it does not seed twice. Seed liquidity remains permanently locked under the existing contract policy.

Run the complete deployment/recovery tests with `python3 scripts/test_deployment.py`; this starts and stops a disposable local Anvil chain. See [deployment instructions](docs/DEPLOYMENT.md) for configuration, testnet, hardware wallets and recovery.

## Repository guide

- [Architecture and rounding](docs/ARCHITECTURE.md)
- [Deployment configuration and recovery](docs/DEPLOYMENT.md)
- [Chart, routing, and P&L integration requirements](docs/INTEGRATION.md)
- [Validation record](docs/VALIDATION.md)
- [Contributing and checks](CONTRIBUTING.md)

Dependencies, build output, generated reports, deployment receipts, virtual environments, and local credentials are ignored by Git. `artifacts/.gitkeep` preserves the output directory in a fresh checkout. Keep real deployment receipts backed up separately; commit only redacted, intentional deployment documentation. `.env.example` is the shared configuration template.
