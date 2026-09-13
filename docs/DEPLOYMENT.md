# Full deployment with liquidity

The full deployment command creates `InverseHook`, `InverseToken`, and `InverseGateway`, approves the quote seed, deposits the seed into the hook vault, initializes the canonical v4 pool, and verifies the resulting network state. All initial shares are already in the vault when the token is created. This supplies the custom market's real liquidity; the native concentrated-liquidity pool remains empty by design.

The workflow has been tested on disposable Anvil chains, including a successful trade after initialization and recovery from partial deployment. No public deployment has been made. DEX Screener/Fomo integration remains a separate [open gate](INTEGRATION.md).

## 1. Configure

```sh
bash scripts/bootstrap.sh
cp .env.example .env
```

Edit `.env`. Foundry reads it as configuration; no shell `source` command is required. Leave an existing `.env` intact if you have already configured it.

| Setting | Meaning |
|---|---|
| `EXPECTED_CHAIN_ID` | Required: Robinhood mainnet `4663`, testnet `46630`, or local `31337` |
| `POOL_MANAGER` | Canonical Uniswap address on mainnet; an explicitly deployed compatible manager on testnet/local |
| `DEPLOYER` | Address of the signing wallet, which will also seed the market |
| `QUOTE_TOKEN` | Reviewed standard ERC-20 quote asset with 6–18 decimals |
| `INITIAL_SHARES` | Fixed ownership supply, in raw 18-decimal share units |
| `INITIAL_QUOTE` | Quote liquidity to deposit, in the quote asset's native raw units |
| `FEE_PPM` | Immutable input fee; `3000` is 0.30%, `0` reproduces the whitepaper example |
| `INVERSE_HOOK` | Leave zero for a deterministic new deployment or retry. Set an existing hook to explicitly resume or verify it |
| `SALT_START` | Defaults to zero. Keep unchanged for retries; change only to intentionally create another market |

The example file uses **1 billion shares** (`1000000000000000000000000000` raw shares) and **1,000 units of a six-decimal quote** (`1000000000` raw quote). The initial normalized share/token price is then `0.000001` quote units. Set raw seed amounts according to the actual quote decimals.

Fund `DEPLOYER` with the configured quote amount and native ETH for gas. Preflight checks reject an unfunded seed before deploying contracts. Foundry estimates transaction gas during simulation. The script checks chain ID, manager, token decimals, supply, fee and price bounds, and verifies existing contract bindings when resuming.

Mainnet uses `0x8366a39CC670B4001A1121B8F6A443A643e40951`; the full workflow rejects a different manager on chain `4663`. The deployment does not choose or mint a production stablecoin for you. Quote behavior and stablecoin issuer controls remain asset-selection considerations.

## 2. Dry run

```sh
python3 scripts/deploy.py --rpc-url robinhood
```

This simulates contract deployment, approval, and liquidity initialization without signing or broadcasting. The configured seeder must have the seed balance on the selected network even for this simulation. Check the printed chain, quote decimals, seed amount, contract addresses, and gas estimate.

The report's stage is `dry_run_only`; its `plan.json` contains simulated balances and is not evidence of a public deployment.

## 3. Deploy and seed

Use the wallet corresponding to `DEPLOYER`:

```sh
python3 scripts/deploy.py --rpc-url robinhood --account YOUR_KEYSTORE --broadcast
```

For a hardware wallet, replace `--account YOUR_KEYSTORE` with `--ledger` or `--trezor`, and add `--sender YOUR_ADDRESS` if needed. The driver delegates wallet access and signing to Foundry. `--unlocked --sender ADDRESS` is available for RPC-managed development accounts, as used in the local tests.

**Successful initialization permanently commits the seed liquidity.** The contracts have no LP withdrawal, seed refund, fee withdrawal, extra share issuance, or owner-controlled liquidity exit. Confirm supply, quote amount and immutable fee before using `--broadcast`.

The driver runs Foundry with `--slow`, waiting for each transaction before proceeding. A normal fresh deployment sends three transactions:

1. Deploy the hook via CREATE2; its constructor creates the token and gateway.
2. Approve the configured quote seed for the hook.
3. Initialize: atomically deposit the quote and initialize the v4 pool.

A quote requiring allowance reset can require an extra approval transaction. If an exact seed approval is already present, it is reused. Initialization itself is atomic; the full multi-transaction deployment is not.

After broadcasting, a separate read-only verifier loads current network state and checks component bindings, configuration, initialized pool, accounted reserve backing, empty inverse-token inventory in PoolManager, settled phase, and deterministic index. It accepts an initialized market that has already traded; it does not reset its price or liquidity.

## Records and recovery

Each invocation prints a unique `artifacts/deployments/<UTC timestamp>-<id>/manifest.json` path. A successful broadcast record includes:

- `plan.json`: the initial Foundry simulation, explicitly marked `simulated`.
- `broadcast.json`: archived public transactions and receipts for this broadcast, when transactions were necessary.
- `state.json`: current network state, marked `verified_on_chain`.
- `manifest.json`: addresses, chain ID, final status, and links to those files.

Amounts that can exceed JavaScript's safe integer range are stored as decimal strings. `evmBlockNumber` is Solidity's block-number value; on Orbit chains it may be a parent-chain estimate rather than the RPC L2 height. Receipts retain the actual RPC block references. RPC credentials and wallet secrets are not added to the manifest. Foundry also maintains its own `broadcast/` receipts; retain these when a broadcast fails. Generated deployment records are ignored by Git, so back up real deployment records separately.

If broadcasting is interrupted, rerun the **same command and configuration**. The script deterministically resolves the same hook even when that address already contains code. It checks existing configuration, reuses deployed components, and initializes only if initialization is missing. An already initialized market produces no new transactions and no additional seed deposit.

An incomplete invocation is marked `incomplete`; some transactions may already have landed. Changing compiler settings, bytecode, quote, seeder, seed values, fee or salt changes deterministic addressing, so do not change those to retry. To resume an older two-step deployment, set its address as `INVERSE_HOOK`; the full workflow validates it before funding. Run deployments sequentially from a given workspace/wallet because Foundry also maintains shared broadcast records.

For a separate read-only verification:

```sh
# Set INVERSE_HOOK to the deployed hook in .env first.
DEPLOYMENT_REPORT=artifacts/live-state.json \
forge script script/VerifyInverseDeployment.s.sol:VerifyInverseDeployment \
  --rpc-url robinhood -vv
```

This is contract-state verification. Explorer source verification is separate and should use the pinned compiler/settings, exact constructor arguments, and all three deployed contract addresses.

## Testnet and local development

For Robinhood testnet, set `EXPECTED_CHAIN_ID=46630`, an actual testnet `POOL_MANAGER`, and testnet quote/deployer addresses, then use `--rpc-url robinhood_testnet`. The official source checked did not list a Robinhood testnet PoolManager; no address is guessed. For an existing local Anvil instance use chain `31337` and `--rpc-url http://127.0.0.1:8545` with deployed manager/quote contracts.

Run the complete disposable integration suite with no wallet or real funds:

```sh
python3 scripts/test_deployment.py
```

It tests preflight funding failure, full dry-run isolation, deployment plus seed and receipts, repeated runs without extra transactions, live trading, recovery after deployment/approval, rejection of unseeded verification, wrong-chain checks and existing-configuration mismatch. Anvil is stopped when the test finishes.

The original `DeployInverse.s.sol` (contracts only) and `InitializeInverse.s.sol` (seed only) remain available for explicit two-step workflows. The new recommended path is `scripts/deploy.py`, which calls `DeployInverseFull.s.sol` and then `VerifyInverseDeployment.s.sol`.

Sources for chain configuration: [Robinhood network settings](https://docs.robinhood.com/chain/connecting/), [Uniswap v4 deployment addresses](https://developers.uniswap.org/docs/protocols/v4/deployments), checked September 13, 2026.
