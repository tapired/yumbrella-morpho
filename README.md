# Yumbrella Morpho

A senior/junior tranche system built on Yearn V3 and Morpho, implementing Design 1: junior vault provides first-loss USDC insurance to protect senior vault depositors.

## Architecture

```
                         ┌─────────────────────────────────────────┐
                         │         SENIOR VAULT (VaultV3.vy)       │
                         │         asset: USDC                     │
                         │                                         │
                         │  Modules (all set to Yumbrella):        │
                         │    ├── accountant                       │
                         │    ├── deposit_limit_module              │
                         │    └── withdraw_limit_module             │
                         │                                         │
                         │  auto_allocate: true                    │
                         │  use_default_queue: true                │
                         │                                         │
                         │  Strategy:                              │
                         │    └── MorphoLossAwareCompounder        │
                         └──────┬──────────────────┬───────────────┘
                                │                  │
                   USDC (auto)  │                  │ process_report()
                                ▼                  ▼
┌───────────────────────────────────┐  ┌───────────────────────────────────┐
│   MorphoLossAwareCompounder       │  │           YUMBRELLA               │
│   (TokenizedStrategy)             │  │      (Base4626Compounder)         │
│                                   │  │                                   │
│   Extends MorphoCompounder.       │  │  Three roles on senior vault:     │
│   Tracks lostAssets() delta from  │  │    • Accountant: fees on profit,  │
│   MetaMorpho to detect and report │  │      USDC refunds on loss         │
│   losses before vault level.      │  │    • Deposit limit: caps senior   │
│                                   │  │      deposits via collateralRatio │
│   ┌───────────────────────────┐   │  │    • Withdraw limit: blocks       │
│   │ MorphoCompounder          │   │  │      withdrawals when losses      │
│   │  • UniswapV3 reward swaps │   │  │      exist                        │
│   │  • Auction reward sales   │   │  │                                   │
│   └───────────┬───────────────┘   │  │  Deposits USDC into yield vault.  │
│               │                   │  │  On profit: receives senior vault  │
│               ▼                   │  │    shares → redeems to USDC on     │
│   ┌───────────────────────────┐   │  │    harvest → PPS increases.        │
│   │  MetaMorpho Vault (ERC4626)│  │  │  On loss: frees USDC from yield   │
│   │  Allocates across Morpho  │   │  │    vault → refunds senior vault.  │
│   │  Blue lending markets     │   │  │                                   │
│   └───────────┬───────────────┘   │  │  Withdraw delay:                  │
│               │                   │  │    requestWithdraw → 7d cooldown   │
│               ▼                   │  │    → 7d window to claim            │
│   ┌───────────────────────────┐   │  └──────────────┬────────────────────┘
│   │  Morpho Blue (lending)    │   │                 │ USDC
│   │  Markets with borrowers   │   │                 ▼
│   └───────────────────────────┘   │  ┌───────────────────────────────────┐
└───────────────────────────────────┘  │  Yield Vault (e.g. yvUSDC-1)     │
                                       │  Earns base yield on junior USDC  │
                                       └───────────────────────────────────┘
```

### Contracts

| Contract | Base | Description |
|---|---|---|
| `Yumbrella.sol` | `Base4626Compounder` | Junior vault. Accountant + deposit/withdraw limit module for senior vault. Deposits USDC into a yield vault. |
| `MorphoLossAwareCompounder.sol` | `MorphoCompounder` | Senior vault strategy. Tracks Morpho vault losses via `lostAssets()` delta. |
| `MorphoCompounder.sol` | `Base4626Compounder` + `UniswapV3Swapper` | Base ERC-4626 compounder for Morpho vaults. Handles reward token swapping. |
| `YumbrellaFactory.sol` | — | Deploys Yumbrella instances with role configuration. |
| `MorphoLossAwareCompounderFactory.sol` | — | Deploys MorphoLossAwareCompounder instances with role configuration. |

### Default Parameters

| Parameter | Value |
|---|---|
| `seniorVaultPerformanceFee` | 1,000 (10%) |
| `refundRatio` | 10,000 (100%) |
| `collateralRatio` | 10e18 (10x) |
| `withdrawCooldown` | 7 days |
| `withdrawWindow` | 7 days |

### Yumbrella Roles on Senior Vault

**Accountant** — Called by the senior vault during `process_report()`. On profit: returns a 10% performance fee. On loss: frees USDC from the yield vault and refunds the senior vault.

**Deposit Limit Module** — Caps senior vault deposits at `Yumbrella_vault_value * collateralRatio`. With default 10x ratio: if Yumbrella has $1M deployed, senior can hold up to $10M.

**Withdraw Limit Module** — Blocks all senior vault withdrawals when any strategy has unrealized losses (via `assess_share_of_unrealised_losses`) or unreported Morpho losses (via `lossExists()`).

## Profit Flow

```
  1. Morpho Blue markets accrue interest
     │
     ▼
  2. Keeper calls morphoLossAwareCompounder.report()
     • vault.deposit(0) syncs MetaMorpho state
     • _calculateLoss() → no new losses
     • returns full balance → profit reported to TokenizedStrategy
     │
     │  profit unlocks over profitMaxUnlockTime (10 days)
     ▼
  3. vaultManagement calls seniorVault.process_report(morphoLossAwareCompounder)
     • Senior vault sees gain from strategy
     • Calls Yumbrella.report(gain=X)
     │
     ▼
  4. Yumbrella.report() handles gain
     • _fees = gain * 10% (seniorVaultPerformanceFee)
     • Returns _fees to senior vault
     • Senior vault mints fee shares to Yumbrella
     • Senior vault PPS increases (depositors keep 90% of gain)
     │
     ▼
  5. Keeper calls yumbrella.report()
     • _harvestAndReport():
       - super._harvestAndReport() compounds yield vault
       - Redeems ALL senior vault shares held → receives USDC
       - _totalAssets += redeemed USDC
     • Yumbrella PPS increases
     • All Yumbrella depositors benefit pro-rata (just hold shares)
```

## Loss Flow

### Loss Detection and Blocking

```
  1. Bad debt in Morpho Blue (borrower liquidated, collateral < debt)
     │
     ▼
  2. MetaMorpho lostAssets() increases (once vault state is synced)
     │
     ▼
  3. MorphoLossAwareCompounder.lossExists() → true
     │
     ├── available_withdraw_limit → 0 (senior withdrawals blocked)
     ├── _tendTrigger → false (compounder must report first)
     └── System waits for compounder to report
```

### Loss Reporting and Compensation

```
  4. Keeper calls morphoLossAwareCompounder.report()
     • vault.deposit(0) syncs MetaMorpho
     • _calculateLoss():
         newLosses = (myShares * lostAssetsDelta) / totalSupply
         lastLostAssetsOnMorpho = current lostAssets (checkpoint updated)
         lastMorphoLosses += newLosses
     • Returns max(0, fullBalance - lastMorphoLosses)
     • Strategy reports loss to TokenizedStrategy
     │
     │  Now: lossExists() = false, assess_share_of_unrealised_losses > 0
     │  _tendTrigger() → true
     ▼
  5a. [TEND PATH] Keeper calls yumbrella.tend()
     • Checks: _loss > 0 AND !_lossExistsOnCompounder
     • If auction set:
         - Frees USDC from yield vault
         - Transfers to auction contract
         - Kicks auction (asset → SENIOR_ASSET)
     • Calls keeper.report(yumbrella) to eat the loss on Yumbrella PPS
     │
     ▼
  5b. [DIRECT PATH] vaultManagement calls
      seniorVault.process_report(morphoLossAwareCompounder)
     • Senior vault sees loss from strategy
     • Calls Yumbrella.report(loss=L)
     │
     ▼
  6. Yumbrella.report() handles loss
     • If auction set: requires auction is filled
     • _refunds = min(loss * refundRatio, valueOfVault())
     • _freeFunds(_refunds) → redeems USDC from yield vault
     • Approves USDC to senior vault
     │
     ▼
  7. Settlement
     • Senior vault receives USDC refund → PPS stays >= 1.0
     • Yumbrella absorbs the loss → PPS drops
     • If loss <= Yumbrella value: senior fully protected
     • If loss >  Yumbrella value: senior takes excess loss
     • Withdrawals re-enabled once unrealized losses = 0
```

### Required Ordering

Loss compensation requires strict sequencing. Each step must complete before the next can proceed:

```
  Step 1: morphoLossAwareCompounder.report()
          Clears lossExists(), makes unrealized losses visible at vault level.
          No on-chain trigger exists — keeper must detect independently.

  Step 2: yumbrella.tend() [optional, if auction path needed]
          Only fires when _loss > 0 AND lossExists() = false.

  Step 3: seniorVault.process_report(morphoLossAwareCompounder)
          Triggers Yumbrella.report() callback → USDC refund.
```

## Morpho Loss Tracking

The `MorphoLossAwareCompounder` tracks losses via MetaMorpho's `lostAssets()` — a monotonically increasing counter of cumulative bad debt.

```
State variables:
  lastLostAssetsOnMorpho  — checkpoint from last report
  lastMorphoLosses        — cumulative losses attributed to this strategy

On each _harvestAndReport():
  1. vault.deposit(0) forces MetaMorpho state sync
  2. delta = lostAssets() - lastLostAssetsOnMorpho
  3. newLosses = (myShares * delta) / totalSupply
  4. lastLostAssetsOnMorpho = lostAssets()   ← checkpoint updated
  5. lastMorphoLosses += newLosses
  6. return max(0, fullBalance - lastMorphoLosses)
```

The checkpoint update (step 4) ensures each `lostAssets()` increment is only counted once. Subsequent reports with no new bad debt produce `delta = 0` and no additional loss.

## Withdrawal Mechanisms

### Senior Vault Withdrawals

Governed by `available_withdraw_limit()`. Returns `type(uint256).max` (unlimited) when no losses detected. Returns `0` (fully blocked) when any strategy has:
- `assess_share_of_unrealised_losses != 0` (loss reported by strategy but not yet processed by vault), OR
- `lossExists() == true` (loss detected in Morpho but not yet reported by strategy)

### Yumbrella (Junior) Withdrawals

Two-phase withdrawal with cooldown:

```
  1. User calls requestWithdraw(shares)
     • Records share count and unlock timestamp
     • Cooldown: 7 days

  2. After cooldown, within 7-day window:
     • availableWithdrawLimit returns min(requestedAssets, available liquidity)
     • User calls withdraw/redeem

  3. If window expires without withdrawal:
     • User must call requestWithdraw again
```

Users continue earning yield (and remain exposed to slashing) during the cooldown period.

## Deposit Limits

Senior vault deposits are capped by the collateral ratio:

```
maxSeniorDeposits = Yumbrella.valueOfVault() * collateralRatio

available_deposit_limit = maxSeniorDeposits - seniorVault.totalAssets()
```

With default 10x ratio, $1M of Yumbrella capital supports up to $10M in senior deposits.

## How to Build and Test

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/en/download/package-manager/)

### Setup

```sh
git clone --recursive <repo-url>
cd yumbrella-morpho
yarn
```

### Environment

Copy `.env.example` to `.env` and set `ETH_RPC_URL` (mainnet fork required for tests).

### Commands

```sh
make build          # Compile contracts
make test           # Run tests
make trace          # Run tests with traces
make coverage       # Generate test coverage
make coverage-html  # Generate HTML coverage report
```

Tests run against a mainnet fork using real USDC, yvUSDC-1, and Morpho vault contracts.
