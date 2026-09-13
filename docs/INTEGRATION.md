# Chart, execution and P&L integration gates

**Open product requirement:** no actual DEX Screener or Fomo listing, inverted candle series, supported gateway route, or reconciled application P&L has been demonstrated for this token. This is a deployment-ready contract prototype, not a completed target-platform integration.

DEX Screener describes its own blockchain-log indexer. Fomo publicly supports Robinhood Chain, but that does not establish support for custom gateway execution or rebasing balances. No public evidence located for this implementation resolves either requirement. Sources: [DEX Screener FAQ](https://docs.dexscreener.com/faq.md), [Fomo's Robinhood announcement](https://newsletter.fomo.family/p/1-300-pump-on-a-mascot-robinhood-integration-and-how-to-save-on-ai).

## Decoder contract

The authoritative finalized price is `EconomicSwap.tokenPriceRay / 1e27` in quote units. Confirm the emitting hook address belongs to the canonical market. Order events by block, transaction index, and log index; deduplicate and handle chain reorganizations. `sequence` increments once per completed trade. `ReservesUpdated` carries its corresponding share and quote reserves. Initialization is sequence zero.

| Field/event | Meaning |
|---|---|
| `EconomicSwap.buy` | Quote-input buy when true; share-input sale when false |
| `shares` | Exact purchased or sold ownership, 18 decimals |
| `quote` | Actual input on a buy or output on a sell, quote-native decimals |
| `settlementTokens` | Floored displayed denomination of traded shares at the old index |
| `finalTokens` | Same traded shares denominated at the new index; on a sale this is a reference quantity, not tokens credited to the seller |
| `feeInput` | Input fee rounded up for reporting, already included in the trade; raw quote on buys and raw shares on sells |
| `indexRay`, `sharePriceRay`, `tokenPriceRay` | Final committed index and normalized prices, each scaled by `1e27` |
| `payer`, `recipient` | Source of input and destination of output; may differ |
| `SharesTransfer` | Exact shares moved, with the effective index |
| `Rebase` | Old/new index; share ownership and economic cost basis do not change |

Native v4 `Swap` events report the zero-amount native curve path and its unchanged price. Native pool-state readers, standard v4 quoters and routes therefore cannot supply the intended price/execution. There is no fabricated native swap event. Transaction-ratio candles also do not suffice: a 1-quote buy followed by a 1,000-quote buy can have rising execution ratios while finalized inverse spot prices fall. The repository explicitly tests this counterexample.

No canonical concentrated-liquidity position exists. A platform may not discover or list the market at all without a decoder integration. Receiving custom events is not proof that a platform uses them.

## Gateway routing

All successful swaps must use `InverseGateway`, including its dedicated share approval for sells. A generic Universal Router route is rejected. Apps must execute through the user's account, quote via `preview`, use share/quote output minimums and a deadline, and read the post-rebase balance. PoolManager callbacks, ERC-6909 settlement claims, exact-output orders and bypass routers are unsupported.

Changing shares held during an ordinary ERC-20 transfer may emit a slightly different nominal transfer amount because of floor rounding. Transfer-only balance reconstruction is inadequate. Reconcile `sharesOf` and `indexRay` directly and process exact share events.

## Cost basis

The contracts preserve cash proceeds; displaying P&L correctly requires application accounting. Store shares and quote cost, not immutable nominal token purchase quantities. With remaining shares `s`, remaining quote basis `C`, and realized P&L `G`:

```
buy:  s += boughtShares; C += quotePaid
sell: basisSold = C * soldShares / s
      G += quoteReceived - basisSold
      C -= basisSold; s -= soldShares
rebase: no change to s, C or G
unrealized = s * sharePrice - C
```

Use rational/high-precision accounting internally; round only for display. For a full exit assign the entire residual basis to the sale. Gas and separate app fees require an explicit policy. External share transfers need basis provenance or an unknown-basis state. A buy sent to a different recipient is not automatically the payer's retained position. Market cap remains an ordinary exposure measure, so it does not count as an inverted token-price chart.

## Evidence required before claiming the target experience

| Gate | Required evidence | Current status |
|---|---|---|
| v4 atomic economics | Real-manager settlement, differential payouts, invariants and rollback checks | Implemented and tested locally; Robinhood fork passed |
| DEX Screener listing and price | Actual listing and candles equal finalized `q`, across small/large unequal buys, alternating sells, several swaps per block and multiple candle intervals | Unverified |
| Fomo price chart | Same observations in the actual application, in token-price mode | Unverified |
| Fomo route | In-app buy, partial sell and exact full-share exit through the gateway | Unverified |
| Fomo holdings/P&L | Share/rebase-aware holdings, remaining basis, realized and unrealized P&L matching actual quote flows | Unverified |
| Asset and operational review | Selected quote behavior, source verification, funding/liquidity policy and independent contract review | Pending |

For probes, retain chain ID, verified contract addresses, deployment block, transaction hashes, decoded economic events, application screenshots/exports and timestamps. Compare the app's candle close to the last finalized `tokenPriceRay` in that interval. Keep the execution ratio and native pool price alongside it to identify the decoder actually being used. Test the 100/100/full-exit example and the 1/1,000 unequal-buy counterexample first.

If the platforms cannot consume this price history and execute the gateway, the intended product remains blocked. A custom chart, a renamed ordinary quote, or an artificial pool price does not resolve that gate.
