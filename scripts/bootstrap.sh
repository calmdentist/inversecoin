#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
forge install --no-git \
  Uniswap/v4-core@e50237c43811bd9b526eff40f26772152a42daba \
  foundry-rs/forge-std@77041d2ce690e692d6e03cc812b57d1ddaa4d505 \
  OpenZeppelin/openzeppelin-contracts@e4f70216d759d8e6a64144a9e1f7bbeed78e7079
