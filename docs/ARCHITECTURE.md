# Accounting and settlement

## Committed economics

`x` is raw ownership-share inventory; `y` is raw quote inventory. Total shares `S` and initial quote reserve `y0` are fixed at construction. All `S` shares are initially held by the vault. For quote decimals `d`, `quoteScale = 10^(18-d)`.

```
sharePriceRay = floor(y * quoteScale * 1e27 / x)
relativePriceRay = floor(y * S * 1e27 / (x * y0))
indexRay = floor(relativePriceRay^2 / 1e27)
balanceOf(i) = floor(sharesOf(i) * indexRay / 1e27)
tokenPriceRay = floor(sharePriceRay * 1e27 / indexRay)
```

The relative-price calculation uses the original reserves directly, avoiding division by a rounded reference-price getter. The result approximates the whitepaper's `r=(P/P0)^2` with deterministic floor rounding. Global rebases conserve every share. Display supply multiplied by token price follows ordinary market capitalization; market capitalization does not invert.

Outputs follow the conventional integer constant-product formula:

```
effective = amountIn * (1_000_000 - feePpm)
amountOut = floor(effective * reserveOut / (reserveIn * 1_000_000 + effective))
```

The full input goes into reserves. `feeInput` in the preview/event is the fee rounded up to the next raw input unit for reporting; that rounded number is not subtracted a second time during curve calculation. The pool key's native LP fee is zero. The immutable custom input fee is entirely retained in the vault. Trades preserve the same discrete reserves and cash outputs as the reference AMM, including ordinary MEV exposure, price impact, and rounding. No extra economic yield comes from rebasing.

## Atomic lifecycle

1. The gateway enters its reentrancy guard and verifies the deadline, recipient, and that PoolManager is locked.
2. `prepare` validates the entire next state and returns the exact quote/share amounts. The hook saves a single pending trade and opens token settlement at the old index. Committed reserves remain unchanged.
3. The gateway calls `PoolManager.unlock` with a hash-authenticated callback. It prepays exact input and settles that credit before invoking the swap.
4. `beforeSwap` accepts only the bound gateway, pool key, direction and exact pending input. The hook takes the prefunded input, delivers the calculated output, and settles. Hook-returned deltas cancel native curve execution and transfer the obligations to the gateway.
5. The gateway validates returned deltas and takes the output directly to the recipient. It reconciles exact recipient shares/quote, checks that manager quote inventory is unchanged from entry, and that manager inverse shares are zero. PoolManager rejects any remaining currency deltas before relocking.
6. Only after `unlock` returns can `finalize` commit accounted reserves and the calculated index, close settlement, and emit the finalized economic state.

Any failure reverts token movements, allowances, pending state, reserves, and the rebase together. There is no public standalone finalization path. A transaction may call the gateway repeatedly, but each trade must finish its own unlock and rebase. Calling the gateway from somebody else's active v4 unlock is rejected.

## Exact shares through ERC-20 settlement

A generic share token can lose share dust if it transfers shares into PoolManager, computes the floored token amount, then converts that token amount back into shares on `take`. This token uses a deliberately narrow solution:

- PoolManager must start and finish each canonical trade with zero inverse shares.
- Only the market and gateway may transfer inverse inventory into PoolManager, and only while settlement is active. Another deposit while inventory exists is rejected.
- PoolManager may transfer out only its **entire** frozen-index token balance in one `transfer`. That transfer moves all backing shares without reconversion.
- The actual token balance increase measured by `settle` equals the amount taken. Incoming and outgoing shares reconcile exactly; there is no synthetic balance override or unbacked settlement token.

These restrictions are intentional composability limits. Other v4 pools and fixed-token ERC-6909 claims cannot custody this token. Canonical native liquidity and donations are rejected by enabled hook callbacks. Native swap events are left truthful and unchanged; no dummy price-moving liquidity is created.

Ordinary wallet token transfers floor the requested amount to shares. The emitted `Transfer` amount is the actual share denomination and may be slightly smaller than requested. Nonzero sub-share transfers revert; zero transfers are supported. `SharesTransfer` records the exact ownership movement. Use share transfers and share approvals when exact ownership matters. Standard ERC-20 allowances remain in nominal units across rebases; share allowances remain in shares. The two ledgers are independent.

## Bounds and exits

| Quantity | Bound |
|---|---|
| Initial shares | `1e18` to `1e30` raw shares |
| Initial normalized share price | `1e-9` to `1e9` quote units per share |
| Quote decimals | 6 to 18 |
| Quote reserves/input | At most `uint112.max` |
| Remaining share reserves | At least `1e9` raw shares; at most the initial supply |
| Relative share price | At most `1e9` times the initial price |
| Index | `1e27` to `1e45`, also bounded so the entire displayed supply fits `int128.max` |
| Each v4 delta | Positive magnitude at most `int128.max` |

Bounds are checked in `preview` before funds move. A violating buy reverts; the index is never clamped. Because all shares originate in the vault, locked liquidity and retained fees imply `x <= S` and `y >= y0`. Selling existing shares decreases the share price/index, increases `x`, and decreases `y`, moving away from the upper bounds. Bounding the **whole supply's** display amount ensures a full position's old-index settlement delta remains representable.

An exit worth less than one raw quote unit has zero output and reverts. Such dust can be combined through share transfers or become sellable after price changes; there is no promised minimum-value redemption. Dust trades can leave displayed prices unchanged through quantization. Typical deployment parameters have much finer precision than the extreme bounds; applications must use previews rather than assume every nominal token unit can be transferred.

Donations are visible as `surplus()` and never enter pricing. They remain permanently stranded in the vault. No admin recovery mechanism exists. External wrappers, bridges, other AMMs and collateral systems need their own rebase integration. The spot getters are manipulable AMM prices, not lending oracles.
