# KyberSwap integration

The integration is a Go hook tracker/simulator in KyberNetwork/kyberswap-dex-lib,
not a new on-chain trading router. It targets the **undeployed fee-aware routed
candidate** pinned by `releases/routed-candidate/manifest.json`. The previous live
Robinhood deployment must not be registered against this model.

Working checkout: `../kyberswap-dex-lib-inverse`, branch
`codex/inverse-token-hook`. The upstream PR and exact commits are recorded here
when published. Source reference branch: `codex/kyber-candidate-reference` in
`calmdentist/inversecoin`; making the repository public is a separate user action.

## What is implemented

- Exact-input buys and sells, including rebase denomination and protocol fees.
- Native v4 position reconstruction, bitmap-word swap steps, LP-fee rounding,
  quote dust losses and the contract's endpoint/custody rejection checks.
- Atomic block-pinned RPC snapshots with state overrides.
- Immutable quote calculations, clone isolation and sequential state updates.
- v4 dispatch, post-rebase reserve updates and msgpack registration/tests.
- 232 execution-derived differential cases, including expected reverts.

Production contracts and the reviewed release manifest are unchanged.

## Reproduce fixtures

```sh
bash scripts/bootstrap.sh
python3 integrations/kyber/export_vectors.py \
  --output ../kyberswap-dex-lib-inverse/pkg/liquidity-source/uniswap/v4/hooks/inverse/testdata/solidity.json
```

This executes the actual PoolManager and candidate contracts locally. It neither
connects to a funded wallet nor sends transactions to Robinhood.

In the Kyber checkout (Go 1.25.10):

```sh
CI=true go test -race ./pkg/liquidity-source/uniswap/v4/... ./pkg/msgpack/...
go test ./pkg/liquidity-source/uniswap/v4/hooks/inverse -run '^$' \
  -fuzz FuzzQuoteDoesNotMutate -fuzztime=30s
go test ./pkg/liquidity-source/uniswap/v4/hooks/inverse -run '^$' -bench BenchmarkQuote
```

## Activation prerequisites

The PR remains a draft until the candidate's source is public and an actual new
deployment can be registered by hook address, immutable parameters and verified
bytecode. Then capture a pinned production snapshot, compare both directions
with the deployed Kyber execution adapter, calibrate gas, and have Kyber deploy
its updated quote service. This does not require modifying the Universal Router.

Initial routing must use one INVERSE leg per transaction, with empty hook data,
exact input, full atomic INVERSE settlement/take, and no persistent INVERSE
ERC-6909 credit. Route builders must not assume nominal balances survive a rebase
unchanged across split routes or cycles. This backend policy lies outside this
public simulator library and is called out for Kyber's review.

An upstream merge alone does not establish production quote availability or
Fomo eligibility. Test those after Kyber activates the verified deployment.
