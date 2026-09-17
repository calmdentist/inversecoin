# Kyber integration candidate reference

This branch pins the undeployed, fee-aware routed candidate and its execution
fixture generator for the Kyber integration PR. It is a source reference, not a
new mainnet deployment or the project's main release branch. Historical source
files inherited from main are not the target of this integration.

Production source: `src/routed/RoutedInverseHook.sol`,
`src/routed/RoutedInverseToken.sol`, and `src/libraries/InverseMath.sol`.
The exact reviewed source/configuration and artifact hashes are in
`releases/routed-candidate/manifest.json`.

```sh
bash scripts/bootstrap.sh
python3 integrations/kyber/export_vectors.py --output /tmp/solidity.json
python3 scripts/check_routed_release.py
```

Use Foundry 1.4.3 and the pinned Solidity 0.8.26/Cancun configuration. The export
executes 232 trades locally against the actual v4-core PoolManager and candidate;
178 succeed and 54 revert. It does not use an RPC, wallet, or private key.
See [integration notes](integrations/kyber/README.md) for adapter scope and release gates.

The seeder can permanently close trading by withdrawing the entire LP position.
Exact-output swaps and arbitrary multi-leg rebase routing are not supported.
The older live Robinhood hook must not be registered against this new simulator.
