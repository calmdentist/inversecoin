# Contributing

Use the pinned dependencies and compiler settings in `dependencies.lock.json` and `foundry.toml`. The [README](README.md) covers initial setup and the current prototype limitations.

## Checks

Run from the repository root:

```sh
bash scripts/bootstrap.sh
forge fmt --check
forge build --sizes
forge test
forge script script/LocalDemo.s.sol:LocalDemo
python3 scripts/test_deployment.py
```

Use `forge fmt` to apply Solidity formatting. GitHub Actions runs the same checks. The default contract suite skips the optional Robinhood fork test; see the README to enable that read-only test. The deployment integration suite starts and stops its own Anvil node and uses development accounts and mock quote tokens.

## Changes

Keep changes focused and describe the resulting behavior and verification in the commit or pull request. Include regression tests for changes to pricing, share accounting, settlement, authorization, or deployment recovery. Preserve payout equivalence to the ordinary share-space AMM and test both buy and sell paths when changing economics.

Update the relevant documentation when changing public methods, configuration, liquidity policy, rounding, or supported integration paths. Do not describe a contract or fork test as proof that a third-party app supports the token; the remaining application requirements are tracked in `docs/INTEGRATION.md`.

## Local files

Keep wallet keys, seed phrases, keystores, credentials, `.env` files, and raw deployment output out of commits. Use `.env.example` for placeholders. Dependencies are installed under the ignored `lib/` directory. Build output, reports, and receipts are generated locally; preserve real deployment records outside Git as needed.
