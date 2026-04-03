# Yumbrella Morpho

A senior/junior tranche system built on Yearn V3 and Morpho. Junior vault (Yumbrella) provides first-loss USDC insurance to protect senior vault depositors. Both senior and junior capital are deployed into the same Morpho compounder for yield.

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
│   Receives USDC from BOTH senior  │  │  vault = MorphoLossAwareCompounder│
│   vault AND Yumbrella.            │  │                                   │
│   Deposit allowlisted.            │  │  Three roles on senior vault:     │
│                                   │  │    • Accountant: fees / refunds   │
│   Tracks lostAssets() delta from  │  │    • Deposit limit: collateral cap│
│   MetaMorpho. Also estimates      │  │    • Withdraw limit: loss gate    │
│   pending losses via on-chain     │  │                                   │
│   Morpho Blue market math before  │  │  Withdraw delay:                  │
│   MetaMorpho syncs.               │  │    requestWithdraw → 7d cooldown  │
│                                   │  │    → 7d window to claim           │
│   ┌───────────────────────────┐   │  └───────────────┬───────────────────┘
│   │  MetaMorpho Vault (ERC4626)│  │                  │
│   │  Allocates across Morpho  │   │                  │ USDC
│   │  Blue lending markets     │   │                  │
│   └───────────┬───────────────┘   │  ┌───────────────▼───────────────────┐
│               ▼                   │  │  Same MorphoLossAwareCompounder   │
│   ┌───────────────────────────┐   │  │  (Yumbrella deposits here too)    │
│   │  Morpho Blue (lending)    │   │  └───────────────────────────────────┘
│   │  Markets with borrowers   │   │
│   └───────────────────────────┘   │
└───────────────────────────────────┘

  Both senior and junior USDC flow into the same compounder:

  Senior Vault ──USDC──► MorphoLossAwareCompounder ──► MetaMorpho ──► Morpho Blue
                              ▲
  Yumbrella    ──USDC─────────┘
```

### Contracts

| Contract | Base | Description |
|---|---|---|
| `Yumbrella.sol` | `Base4626Compounder` | Junior vault. Accountant + deposit/withdraw limit module for senior vault. Deposits USDC into the MorphoLossAwareCompounder. |
| `MorphoLossAwareCompounder.sol` | `MorphoCompounder` | Shared strategy. Receives USDC from both senior vault and Yumbrella. Tracks Morpho losses via `lostAssets()` delta and on-chain pending loss estimation. Deposit-allowlisted. |
| `MorphoCompounder.sol` | `Base4626Compounder` + `UniswapV3Swapper` | Base ERC-4626 compounder for Morpho vaults. Handles reward token swapping via Uniswap V3 or auctions. |
| `YumbrellaKeeper.sol` | — | Keeper coordinator. Orchestrates report/tend calls across the trio. Chains the full loss-sync flow in a single transaction. |
| `TrioFactory.sol` | — | One-shot deployment of the full trio (compounder + senior vault + Yumbrella) with all wiring and role setup. |
| `MinimalMorphoExpectedSupplyLib.sol` | — | On-chain library to estimate expected supply assets per Morpho Blue market. Used by `viewPendingLostAssets()` to detect losses before MetaMorpho syncs. |

### Default Parameters

| Parameter | Value |
|---|---|
| `seniorVaultPerformanceFee` | 1,000 (10%) |
| `refundRatio` | 10,000 (100%) |
| `collateralRatio` | 10e18 (10x) |
| `withdrawCooldown` | 7 days |
| `withdrawWindow` | 7 days |
| `yumbrellaLossLimitRatio` | 9,999 (99.99%) |
| `morphoLossLimitRatio` | 5,000 (50%) |

### Yumbrella Roles on Senior Vault

**Accountant** — Called by the senior vault during `process_report()`. On profit: returns a 10% performance fee (senior vault mints fee shares to Yumbrella). On loss: frees USDC from the compounder and refunds the senior vault.

**Deposit Limit Module** — Caps senior vault deposits at `Yumbrella_vault_value * collateralRatio`. With default 10x ratio: if Yumbrella has $1M deployed, senior can hold up to $10M.

**Withdraw Limit Module** — Blocks all senior vault withdrawals when any strategy has unrealized losses (via `assess_share_of_unrealised_losses`) or unreported Morpho losses (via `lossExists()`).

## Deployment

The `TrioFactory` deploys and wires the full system in a single transaction:

1. Deploys `MorphoLossAwareCompounder`
2. Deploys senior vault via Yearn V3 `VaultFactory`
3. Deploys `Yumbrella` (with `yieldVault` = compounder when `yieldVault` param is `address(0)`)
4. Wires all modules: accountant, deposit/withdraw limits, strategy, auto-allocate
5. Registers the trio in `YumbrellaKeeper`
6. Sets deposit allowlist on compounder

```solidity
(address yumbrella, address compounder, address seniorVault) =
    trioFactory.deployTrio(TrioFactory.DeployParams({
        asset: USDC,
        yieldVault: address(0),       // uses compounder as yield vault
        morphoVault: metamorphoVault,
        assetToSeniorOracle: oracle,
        ...
    }));
```

## Keeper Architecture

The `YumbrellaKeeper` contract coordinates all report and tend operations across the trio. It is set as the `keeper` for both strategies and has roles on the senior vault.

```
                    ┌─────────────────────────────┐
                    │       YumbrellaKeeper        │
                    │                              │
                    │  Authorized keepers call:    │
                    │    • report()                │ ← full loss-sync
                    │    • reportYumbrella..       │
                    │      AndMorpho()             │ ← normal harvest
                    │    • reportSeniorVault()     │
                    │    • tendYumbrella()          │
                    │    • tendMorpho()             │
                    │    • kickAuction()            │
                    └──┬──────────┬──────────┬─────┘
                       │          │          │
                       ▼          ▼          ▼
                 Compounder  Senior Vault  Yumbrella
```

### Off-Chain Monitoring

The off-chain keeper infrastructure only needs to monitor a single on-chain signal:

```
morphoLossAwareCompounder.tendTrigger()
```

Under normal operation, this returns `false`. When it returns `true`, a loss has been detected in the Morpho vault. The keeper should then call:

```
morphoLossAwareCompounder.tend()
```

This triggers the full automated loss-sync chain:

```
  morphoLossAwareCompounder.tend()
     │
     │  _tend() detects lossExists() == true
     │  Calls YumbrellaKeeper.report(address(this))
     ▼
  YumbrellaKeeper.report() executes in order:
     │
     ├── 1. morphoLossAwareCompounder.report()
     │      Updates loss tracking, reports loss to TokenizedStrategy.
     │
     ├── 2. seniorVault.process_report(morphoLossAwareCompounder)
     │      Senior vault processes loss, calls Yumbrella.report() as
     │      accountant. Yumbrella frees USDC and refunds senior vault.
     │
     └── 3. yumbrella.report()
            Updates Yumbrella total assets and PPS after loss absorption.
```

The entire loss detection, reporting, and compensation flow completes atomically in a single transaction. No manual multi-step coordination is required.

For routine profit harvesting, the keeper calls:

```
yumbrellaKeeper.reportYumbrellaAndMorphoLossAwareCompounder(compounder)
```

This reports both the compounder and Yumbrella. Senior vault `process_report` is called separately by vault management or via `yumbrellaKeeper.reportSeniorVault()`.

## Profit Flow

```
  1. Morpho Blue markets accrue interest
     │
     ▼
  2. Keeper calls keeper.reportYumbrellaAndMorphoLossAwareCompounder()
     • morphoLossAwareCompounder.report():
       - vault.deposit(0) syncs MetaMorpho state
       - _calculateLoss() → no new losses
       - Returns full balance → profit reported
     │
     │  Profit unlocks over profitMaxUnlockTime (10 days)
     ▼
  3. seniorVault.process_report(morphoLossAwareCompounder)
     • Senior vault sees gain from strategy
     • Calls Yumbrella.report(gain=X) as accountant
     • _fees = gain * 10%
     • Senior vault mints fee shares to Yumbrella
     • Senior vault PPS increases (depositors keep 90% of gain)
     │
     ▼
  4. yumbrella.report()
     • _harvestAndReport():
       - super._harvestAndReport() compounds compounder position
       - Redeems ALL senior vault shares held by Yumbrella → USDC
       - USDC redeployed into compounder via _deployFunds
       - _totalAssets increases by redeemed amount
     • Yumbrella PPS increases
     • All Yumbrella depositors benefit pro-rata
```

**Profit cycle**: senior vault shares → redeem to USDC → deposit back into compounder. Fee income is realized in-kind and compounded.

## Loss Flow

### Step 1: Loss Detection — Withdrawals Blocked

```
  Bad debt in Morpho Blue (borrower liquidated, collateral < debt)
     │
     ▼
  MorphoLossAwareCompounder.lossExists() → true
     │
     │  Two detection methods:
     │    1. lostAssets() > lastLostAssetsOnMorpho
     │       (MetaMorpho already synced)
     │    2. viewPendingLostAssets() > lostAssets()
     │       (estimates loss from on-chain Morpho Blue market
     │        state BEFORE MetaMorpho syncs)
     │
     ├── available_withdraw_limit → 0  (senior withdrawals blocked)
     └── compounder _tendTrigger → true
```

### Step 2: Compounder Tend Triggers Full Loss-Sync

```
  Keeper calls morphoLossAwareCompounder.tend()
     │
     │  _tend() detects lossExists() == true
     │  Calls YumbrellaKeeper.report(address(this))
     ▼
  ┌─────────────────────────────────────────────────────┐
  │  2a: morphoLossAwareCompounder.report()              │
  │    • vault.deposit(0) syncs MetaMorpho state          │
  │    • _calculateLoss(): measures delta of lostAssets()  │
  │    • Updates lastLostAssetsOnMorpho checkpoint         │
  │    • Reports loss to TokenizedStrategy                 │
  │    • Compounder PPS drops                              │
  └──────────────────────┬──────────────────────────────┘
                         ▼
  ┌─────────────────────────────────────────────────────┐
  │  2b: seniorVault.process_report(compounder)          │
  │    • Senior vault sees loss from strategy              │
  │    • Calls Yumbrella.report(loss=L) as accountant      │
  │    • _refunds = min(loss * 100%, valueOfVault())       │
  │    • _freeFunds(_refunds) → withdraws USDC from        │
  │      compounder                                         │
  │    • Approves USDC to senior vault                      │
  │    • Senior vault PPS stays >= 1.0                      │
  └──────────────────────┬──────────────────────────────┘
                         ▼
  ┌─────────────────────────────────────────────────────┐
  │  2c: yumbrella.report()                              │
  │    • _harvestAndReport() updates total assets          │
  │    • Redeems any senior vault shares                   │
  │    • Yumbrella PPS drops (double loss absorbed)        │
  └─────────────────────────────────────────────────────┘
```

### Junior Double Loss

Because Yumbrella deposits into the same compounder as senior, losses hit junior twice:

```
  Example: $100 senior, $30 junior, 10% Morpho loss

  1. Compounder loss: $130 * 10% = $13 total loss
     Yumbrella's share: ~$3 (proportional to its compounder position)
     → Yumbrella value drops from $30 to ~$27

  2. Senior vault refund: senior lost ~$10 from its position
     Yumbrella refunds $10 USDC from compounder
     → Yumbrella value drops from ~$27 to ~$17

  Result: senior stays whole at $100, junior goes from $30 to ~$17
```

This is by design — junior sells insurance AND is co-invested. Stronger senior protection than pure subordinated exposure because the refund mechanism tops up senior regardless of compounder PPS.

## Loss Detection: Pending Loss Estimation

`MorphoLossAwareCompounder` has two levels of loss detection to minimize the window between bad debt and withdrawal blocking:

**Level 1: `lostAssets()` check** — Compares MetaMorpho's `lostAssets()` against the stored checkpoint. Detects losses after MetaMorpho has synced.

**Level 2: `viewPendingLostAssets()`** — Iterates over MetaMorpho's withdraw queue, computes expected supply assets per market using `MinimalMorphoExpectedSupplyLib` (on-chain Morpho Blue interest accrual math), and compares against `lastTotalAssets - lostAssets`. Detects losses **before MetaMorpho syncs** by reading raw Morpho Blue market state.

```solidity
function lossExists() public view returns (bool) {
    uint256 lostAssetsOnMorpho = IMetaMorpho(address(vault)).lostAssets();
    if (lostAssetsOnMorpho > lastLostAssetsOnMorpho) return true;
    return viewPendingLostAssets() > lostAssetsOnMorpho;
}
```

## Morpho Loss Tracking

The `MorphoLossAwareCompounder` tracks realized losses via MetaMorpho's `lostAssets()` — a monotonically increasing counter of cumulative bad debt.

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
- `lossExists() == true` (loss detected in Morpho, including pending unreported losses)

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

The MorphoLossAwareCompounder uses an allowlist (`allowed` mapping) to restrict deposits to the senior vault and Yumbrella only.

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

Tests run against a mainnet fork using real USDC and Morpho vault contracts.
