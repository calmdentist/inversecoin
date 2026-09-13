# Inverse-Price Token
## Share-Based Rebasing with Ordinary Trading Economics

**Technical whitepaper · v0.1 · September 12, 2026**  
**Preferred deployment:** Uniswap v4 on Robinhood Chain  
**Target experience:** Inverted token-price charts on DEX Screener and Fomo, with ordinary trading proceeds and correctly displayed P&L.

> **Status:** Proposed architecture. The economic identities below hold under the stated assumptions; the numerical example is verified with exact arithmetic. No contracts or third-party integrations have been validated. Chart decoding, settlement, routing, and application P&L are mandatory release gates—not assumed capabilities.

## 1. Design objective

A buy should lower the token's marginal dollar price; a sell should raise it. Nevertheless, a holder should retain the same economic exposure as in an ordinary market: subsequent buying increases their position value, and selling realizes the ordinary market's proceeds.

The mechanism changes **tokens per ownership share**, not economic ownership. A falling unit price is offset by a growing token balance. This is neither short exposure nor a source of additional yield.

The preferred execution environment is v4 custom accounting on Robinhood Chain. Uniswap has announced v4 availability on that chain [1], and v4 supports replacement pricing curves through hook-returned deltas [2]. Neither establishes compatibility with this particular token.

## 2. Economic model

### Definitions

All equations use decimal-normalized amounts. The quote asset is an approved dollar stablecoin, assumed worth exactly $1 for this model.

| Symbol | Meaning |
|---|---|
| $x$, $y$ | Market reserves: ownership shares and quote currency |
| $P=y/x$ | Marginal quote price per ownership share, before trading fees |
| $P_0>0$ | Immutable reference share price, set at initialization |
| $s_i$, $S$ | Account $i$'s shares and total shares outstanding |
| $r$ | Displayed tokens per share; one at $P=P_0$ |
| $B_i=s_i r$ | Account's displayed token balance |
| $q=P/r$ | Marginal quote price per displayed token |

Ownership shares are the token's internal accounting units, **not LP shares or fixed-value redemption claims**. Fix $S$ at initialization; trades transfer shares and rebases never mint them. Shares-based external balances have an established precedent, although the price-linked rule proposed here differs from existing staking rebases [3].

### Inverse-price rule

Set the global rebase index to:

$$
r(P)=\left(\frac{P}{P_0}\right)^2.
$$

Then:

$$
q(P)=\frac{P}{r(P)}=\frac{P_0^2}{P},
\qquad
\frac{dq}{dP}=-\frac{P_0^2}{P^2}<0.
$$

An ordinary market buy raises $P$ and therefore lowers $q$; a sell does the reverse. On a logarithmic price axis, the relationship is an exact vertical reflection:

$$
\log q=2\log P_0-\log P.
$$

The holder's spot-marked position value remains:

$$
V_i=B_iq=(s_i r)\frac{P}{r}=s_iP.
$$

For a holder who does not trade, doubling $P$ quadruples their balance, halves the unit price, and doubles position value. Share ownership $s_i/S$ is unchanged: the rebase creates neither dilution nor free wealth.

**Market cap does not invert:** with displayed supply $N=Sr$, $Nq=SP$. Likewise, spot value is not guaranteed liquidation value; finite exits incur ordinary price impact and fees. If the quote asset depegs, these equations remain exact in quote units, not necessarily dollars.

## 3. Trading and fees

Use a constant-product market in **share space**. Without fees, $xy=k$.

For a buy spending $a>0$ quote units:

$$
y'=y+a,\qquad x'=\frac{xy}{y+a},\qquad
\Delta s_{\mathrm{out}}=x-x'.
$$

For a sell delivering $d>0$ shares:

$$
x'=x+d,\qquad y'=\frac{xy}{x+d},\qquad
b_{\mathrm{out}}=y-y'.
$$

After settlement, compute $P'=y'/x'$ and commit $r'=(P'/P_0)^2$.

For an input fee $0\le f<1$ retained in the market, use:

| Direction | Actual post-trade reserves | User output |
|---|---|---|
| Buy | $x'=xy/[y+(1-f)a]$; $y'=y+a$ | $x-x'$ shares |
| Sell | $x'=x+d$; $y'=xy/[x+(1-f)d]$ | $y-y'$ quote |

Here $xy$ is the **pre-trade** product; retained fees increase the product. Compute the new index from actual accounted post-trade reserves, not fee-discounted input balances.

Because these reserve and share transitions match an ordinary constant-product market, cash proceeds match that market for the same quote inputs, share quantities sold, and fee rules. Equivalence is **not** defined using unchanged nominal token quantities across rebases. An immediate buy/full-exit round trip returns the starting cash without fees; it loses applicable costs with fees.

### Worked example

Initialize $x=y=1{,}000$, $P_0=1$, with zero fees. Alice buys for $100; Bob then buys for $100; Alice sells all her shares.

| State after action | Share price $P$ | Token price $q$ | Alice's token balance | Alice's cash flow |
|---|---:|---:|---:|---:|
| Initial state | $1.000000 | $1.000000 | 0 | — |
| Alice buys | $1.210000 | $0.826446 | 133.100000 | −$100 |
| Bob buys | $1.440000 | $0.694444 | 188.509091 | $0 |
| Alice exits | $1.170653 | $0.854224 | 0 | +$118.032787 |

Alice owns $1{,}000/11$ shares after buying. Her exit receives $7{,}200/61$ quote units: **$18.032787 profit**, excluding gas. Both buys lower $q$; the sale raises it.

## 4. Proposed v4 architecture

### Components

| Component | Responsibility |
|---|---|
| **Rebasing token** | Stores ownership shares and a committed index; exposes rebased `balanceOf()` and `totalSupply()`, plus share conversion and share-transfer methods. |
| **Market vault / hook** | Holds real reserves, accounts in shares and quote units, implements the curve through custom deltas, and authenticates the canonical pool and execution gateway. |
| **Atomic gateway** | Accepts trades, checks share/quote slippage limits, coordinates v4 settlement, and commits the deterministic rebase. |
| **Read interface / events** | Exposes reserves, index, share price, token price, share movements, quote flows, and fees for independent reconciliation. |

Use one canonical pool initially. Reserve custody remains outside `PoolManager` between trades. Do not back fixed-token-unit ERC-6909 claims or native concentrated-liquidity positions with these rebasing reserves. LP ownership, if offered, uses a separate proportional vault ledger; proportional liquidity changes should preserve $y/x$.

### Atomic settlement convention

**Freeze the index during settlement; update it only afterward.** Do not implement `balanceOf()` by continuously recomputing the index from mutable pool reserves.

The reference transaction sequence is:

```text
Enter non-reentrant gateway; snapshot committed index r_old
  → Execute one canonical trade inside PoolManager.unlock(...)
  → Transfer inputs and outputs using r_old; reconcile actual shares
  → Settle every router/hook currency delta and remove settlement inventory
  → Return from unlock after PoolManager has relocked
  → Derive r_new from accounted post-trade reserves; commit rebase
  → Emit finalized economic state and return to caller
```

For a buy, the purchased shares transfer at $r_{\mathrm{old}}$; their final displayed balance uses $r_{\mathrm{new}}$. For a sell, the delivered shares are determined before rebasing. Settlement failures or failed limits revert the entire transaction.

v4 settlement measures ERC-20 balance changes and requires outstanding deltas to close [4,5]. Changing the denomination mid-settlement could therefore mistake a rebase for payment or create a deficit. The sequence above is a proposed safeguard, **not an audited settlement implementation**.

Require the canonical hook to reject swap paths that bypass this sequencing. Anyone may call the gateway, but arbitrary routers cannot skip finalization. This creates a real integration dependency: Fomo's route must invoke a compatible execution path. Existing use of v4 or a standard router is insufficient evidence.

MVP orders are exact quote-input buys and exact share-input sells, with `minSharesOut`, `minQuoteOut`, and deadlines. A token-amount sell converts at the transaction's committed index; “sell all” uses the actual share balance. Return both settlement-unit amounts and final rebased quantities.

## 5. Chart compatibility: the decisive unresolved requirement

The desired price series is **$q$ after each finalized swap**, using the index effective at that moment—not $P$, market cap, or split-adjusted historical prices.

DEX Screener documents a proprietary blockchain-log indexer [7]. In v4, the native `Swap` event is emitted before final hook-adjusted accounting; a full custom-accounting bypass can leave the native price unchanged [5,6]. Thus, emitting a separate `EconomicSwap` or `Rebase` event does not guarantee either target platform will consume it.

There is a second distinction: **execution ratios are not post-trade spot prices**. Under the frozen-index settlement above, a fee-free buy with $t=a/y$ produces:

$$
\frac{a}{r_{\mathrm{old}}\Delta s_{\mathrm{out}}}
=q_{\mathrm{old}}(1+t),
\qquad
q_{\mathrm{new}}=\frac{q_{\mathrm{old}}}{(1+t)^2}.
$$

Consequently, transaction-ratio candles need not move inversely on every buy. From the example's initial reserves, a $1 buy followed by a $1,000 buy lowers post-trade $q$ from approximately $0.998003$ to $0.249750$, while the corresponding settlement execution ratios **rise** from $1.001000$ to $1.995009$.

**The mathematical inversion is not yet a chart-complete implementation.** Both apps must actually display the required price history. Do not spoof native events, mislabel quotes, or manufacture a cosmetic pool price disconnected from execution. A custom chart alone does not satisfy the product requirement.

Solana `ScaledUiAmount` is not the default fallback: its documentation permits unaware applications to display the ordinary unscaled price [8]. Switching chains requires positive compatibility evidence, not merely a scaling feature.

## 6. P&L accounting

Track economic cost basis in **shares and quote currency**, never immutable per-token purchase prices.

For a position with no external transfers, let $C$ be remaining quote cost basis and $G$ cumulative realized P&L. On a buy, add purchased shares and actual acquisition cost. On a sale of $d$ shares from a position of $s$ shares, average-cost accounting gives:

$$
C_{\mathrm{sold}}=C\frac{d}{s},\qquad
\Delta G=b_{\mathrm{net}}-C_{\mathrm{sold}},\qquad
C'=C-C_{\mathrm{sold}}.
$$

Unrealized P&L is $sP-C=Bq-C$. A rebase changes neither shares nor cost basis. Separately record gas and application fees, with an explicit inclusion policy. External transfers require share-level basis transfer or an “unknown basis” state.

Rebases can change balances without individual ERC-20 `Transfer` events [3]. A transfer-only portfolio indexer may therefore show wrong holdings or P&L. Correct token math and correct cash-out are insufficient: **Fomo must reconcile both the rebased balance and its cost basis**.

## 7. Implementation and security constraints

**Share conservation and precision.** Enforce $\sum_i s_i=S$, including vault and fee holdings. With fixed-point scale $F$, store $R=\lfloor Fr\rfloor$ and expose $B_i=\lfloor s_iR/F\rfloor$. Normalize decimals, use full-precision multiplication/division, specify rounding at each conversion, bound dust, and test signed v4 amount limits. Quantized dust trades may leave the displayed price unchanged.

**Deterministic control.** Fix $P_0$ and the rebase rule. Only atomic finalization may change the index, deriving it from accounted reserves rather than caller-supplied prices. No discretionary share minting, selective holder rebases, or hidden transfer taxes. Segregate unsolicited donations from accounted liquidity.

**Custody and composability.** Prove reserve/share reconciliation through the full unlock lifecycle, including token-rounding effects. Prevent reentrancy and unsupported native liquidity/claim paths for the canonical market. Rebases affect all token holders, including other contracts; external pools, wrappers, bridges, and collateral systems receive no compatibility guarantee.

**Economic attacks and bounds.** Test sandwiches, flash-funded round trips, repeated tiny swaps, reserve exhaustion, and attempts to exploit pending versus committed state. Rebasing must provide no extra extraction beyond the corresponding ordinary market. Predefine index/reserve bounds and safe exit behavior before any bound is reached; silently clamping the index breaks the inverse-price rule.

## 8. Release criteria

| Gate | Required evidence |
|---|---|
| **Economic equivalence** | Differential tests against an ordinary share-space AMM across randomized buys, sells, fees, and partial exits; no share creation or unfunded payouts. |
| **Atomic settlement** | Successful finalization or full revert, with no unsettled obligations, stale index, rounding exploit, or bypass route. |
| **DEX Screener and Fomo charts** | Actual target-app price history follows the intended inversion across unequal trade sizes, alternating directions, multiple trades per block, and multiple candle intervals. Market-cap mode does not count. |
| **Fomo execution and P&L** | In-app buys, partial sells, and full exits work; holdings, remaining basis, and realized/unrealized P&L reconcile with shares and cash flows. |
| **Operational safety** | Confirm chain deployments and routing, pin reviewed contract versions, document liquidity/control policies, and obtain independent review before public funding. |

Run the chart and Fomo-routing probes **before** production hardening. Failure of either is a product-level blocker requiring a demonstrated alternative implementation or platform integration—not a successful launch with a disclaimer.

**Conclusion:** Share-based rebasing can invert the marginal token-price curve while preserving ordinary market exposure and proceeds. Uniswap v4 on Robinhood Chain is the preferred prototype environment. The product is complete only when both target apps display the inverted chart and Fomo preserves normal trading and P&L.

## References

Primary sources checked September 12, 2026. External platform facts are cited; the proposed mechanism and calculations are derived in this paper. Mutable source branches must be pinned to reviewed commits before implementation.

1. [Uniswap Labs — Uniswap is Live on Robinhood Chain](https://blog.uniswap.org/robinhood-chain-is-live).
2. [Uniswap Developers — Custom Accounting](https://developers.uniswap.org/docs/protocols/v4/guides/custom-accounting).
3. [Lido — Rebase, share accounting, and transfer semantics](https://docs.lido.fi/contracts/lido/).
4. [Uniswap Developers — Flash Accounting](https://developers.uniswap.org/docs/protocols/v4/guides/flash-accounting).
5. [Uniswap v4 core — PoolManager.sol: unlock, swap events, and settlement](https://github.com/Uniswap/v4-core/blob/main/src/PoolManager.sol).
6. [Uniswap v4 core — Pool.sol: native swap state and zero-amount path](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Pool.sol).
7. [DEX Screener — FAQ: blockchain data and custom indexing](https://docs.dexscreener.com/faq.md).
8. [Solana — Scaled UI Amount Integration Guide](https://solana.com/docs/tokens/extensions/scaled-ui-amount/integration-guide).
