# Heiken Ashi Trend EA

Client project. MQL5 Expert Advisor for MetaTrader 5 that trades the direction
of closed Heiken Ashi candles on any broker supported instrument.

## Strategy

- Green Heiken Ashi candle closes -> BUY
- Red Heiken Ashi candle closes -> SELL
- Only closed candles are used, the forming candle is ignored
- On a direction change, the current position is closed and the new
  direction is opened immediately
- No duplicate trades are opened while the signal direction is unchanged
- Heiken Ashi timeframe is a selectable input (M1, M5, M15, H1, etc), and is
  independent of the chart timeframe the EA is attached to

## Instruments

Works on any MT5 supported symbol: forex pairs, XAUUSD/metals, oil, indices,
Deriv synthetic/volatility indices, and other broker CFDs. The EA only reads
OHLC data and places trades on `_Symbol`, so it is not tied to gold or forex
specifically.

## Risk management

- Adjustable fixed lot size
- Optional Stop Loss on/off, in points
- Optional Take Profit on/off, in points
- Maximum slippage on order execution, in points
- Optional maximum spread filter, in points
- Magic number so the EA only manages its own positions, and never touches
  manual trades or other EAs on the same chart/account

## Trading time and daily protection

- Adjustable start time and stop time (server time, `HH:MM`)
- At the start time, the account balance or equity (configurable) is
  recorded as that day's starting capital
- Adjustable daily profit % target and daily loss % limit
- When either is hit, all EA positions are closed and trading is blocked
  until the next start time
- At the next start time, the daily starting capital is recalculated
  automatically

## Dashboard

On chart panel showing: EA status, current signal direction, open trade and
lot size, floating P/L, daily P/L in currency and %, daily starting capital,
current spread, configured trading window, and the daily profit/loss limits.

## Files

- `HeikenAshiTrendEA.mq5` — full EA source

## Status

Initial build delivered. Compiles clean in MetaEditor, ready for strategy
tester validation and live parameter tuning per client feedback.
