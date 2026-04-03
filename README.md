# Multi-Pair Arbitrage Grid Bot

A statistical arbitrage Expert Advisor for MetaTrader 5 that trades correlated currency pairs using a grid/DCA approach with intelligent lot scaling.

## Strategy Overview
- **Type**: Multi-Pair Statistical Arbitrage with Grid/DCA
- **Pairs**: EURUSD, AUDJPY, AUDCAD, GBPAUD, AUDNZD (configurable)
- **Timeframe**: Any (trend detection on H1 by default)
- **Direction**: Auto-detected via Moving Average or manually set per pair

## How It Works
1. **Trend Detection**: Uses an MA on the H1 timeframe to determine BUY or SELL direction per pair
2. **Initial Entry**: Opens a 0.01 lot position when direction is confirmed
3. **Grid Scaling**: If price moves against the position by X pips, opens another position with a larger lot size (0.01 → 0.02 → 0.03...)
4. **Basket TP**: When the combined profit of all positions on a pair reaches the target ($5 default), all positions for that pair are closed
5. **Emergency Stop**: If account drawdown exceeds the threshold (30% default), all positions are closed

## Key Features
- Multi-pair support from a single EA instance
- Configurable grid spacing (default: 12 pips)
- Three lot scaling modes: Fixed, Additive (1x,2x,3x), Multiplicative (1x,2x,4x)
- Per-pair basket profit management
- Emergency drawdown protection
- Spread filter to avoid high-spread entries
- Correlated pair basket trading (AUD basket, EUR standalone, etc.)

## Input Parameters
| Parameter | Default | Description |
|---|---|---|
| Grid Spacing | 12 pips | Distance between grid levels |
| Max Grid Levels | 5 | Maximum positions per pair |
| Base Lot Size | 0.01 | Starting lot size |
| Lot Scale Mode | Additive | 0=Fixed, 1=Additive, 2=Multiply |
| Basket TP | $5.00 | Close pair basket at this profit |
| Max Drawdown | 30% | Emergency close threshold |
| Trend TF | H1 | Timeframe for trend detection |
| Trend MA Period | 50 | Moving Average period |

## Installation
1. Copy `Arbitrage_Grid_Bot.mq5` to your MT5 `MQL5/Experts/` directory
2. Open MetaEditor and compile (`F7`)
3. Attach the EA to any chart (it manages all pairs internally)
4. Enable "Allow Algo Trading" in the EA settings
5. Enable "Algo Trading" in the MT5 toolbar

## Risk Warning
⚠️ Grid/DCA strategies can incur significant drawdowns during strong trending markets. Always test on a demo account first. This code is for educational purposes only.
