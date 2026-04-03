//+------------------------------------------------------------------+
//|                                           Arbitrage_Grid_Bot.mq5 |
//|                                  Copyright 2026, Antigravity AI  |
//|                              Multi-Pair Statistical Arbitrage Bot |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://github.com/AlessandroGCodeca"
#property version   "2.00"
#property description "Multi-pair grid/DCA arbitrage bot with pending limit orders"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

//--- Grid Settings
input int      InpGridSpacingPips   = 12;        // Grid Spacing (pips between levels)
input int      InpMaxGridLevels     = 5;         // Max Grid Levels per pair
input double   InpBaseLotSize       = 0.01;      // Base Lot Size (Level 1)
input int      InpLotScaleMode      = 1;         // Lot Scale: 0=Fixed, 1=Additive(1x,2x,3x), 2=Multiply(1x,2x,4x)

//--- Profit Management
input double   InpBasketTPDollars   = 5.0;       // Basket Take Profit ($) per pair
input double   InpMaxDrawdownPct    = 30.0;      // Max Account Drawdown (%) - Emergency Close
input int      InpIndividualSLPips  = 0;         // Per-Trade SL (pips, 0 = none)
input int      InpIndividualTPPips  = 0;         // Per-Trade TP (pips, 0 = none)

//--- Pair Configuration (comma-separated)
input string   InpPairList          = "EURUSD,AUDJPY,AUDCAD,GBPAUD,AUDNZD";  // Pairs to Trade
input string   InpDirections        = "AUTO,AUTO,AUTO,AUTO,AUTO";              // Direction: AUTO, BUY, or SELL

//--- Trend Detection
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_H1;  // Trend Detection Timeframe
input int      InpTrendMAPeriod     = 50;         // Trend MA Period
input int      InpTrendMAMethod     = 0;          // MA Method: 0=SMA, 1=EMA

//--- Timing
input int      InpMaxSpreadPips     = 5;          // Max spread (pips) to allow entry
input bool     InpUsePendingOrders  = true;       // Use Pending Limit Orders (true) or Market Orders (false)

//--- General
input ulong    InpMagicNumber       = 888888;     // Magic Number
input string   InpTradeComment      = "ArbGrid";  // Trade Comment

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;

#define MAX_PAIRS 10

string         g_pairs[];                         // Parsed pair names
int            g_pairCount = 0;                   // Number of active pairs
int            g_directions[];                    // 0=AUTO, 1=BUY, 2=SELL
int            g_trendMA_handles[];               // MA indicator handles per pair
double         g_peakBasketProfit[];              // Peak basket profit for trailing
bool           g_gridPlaced[];                    // Whether pending grid has been placed for this pair

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Setup trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Parse pairs
   g_pairCount = ParseCSV(InpPairList, g_pairs);
   if(g_pairCount <= 0)
     {
      Print("ERROR: No valid pairs in InpPairList");
      return INIT_FAILED;
     }

   // Parse directions
   string dirStrings[];
   int dirCount = ParseCSV(InpDirections, dirStrings);
   ArrayResize(g_directions, g_pairCount);
   for(int i = 0; i < g_pairCount; i++)
     {
      if(i < dirCount)
        {
         string d = dirStrings[i];
         StringTrimLeft(d);
         StringTrimRight(d);
         StringToUpper(d);
         if(d == "BUY")       g_directions[i] = 1;
         else if(d == "SELL") g_directions[i] = 2;
         else                 g_directions[i] = 0; // AUTO
        }
      else
         g_directions[i] = 0; // Default AUTO
     }

   // Initialize tracking arrays
   ArrayResize(g_peakBasketProfit, g_pairCount);
   ArrayResize(g_trendMA_handles, g_pairCount);
   ArrayResize(g_gridPlaced, g_pairCount);

   // Validate symbols and create MA handles
   for(int i = 0; i < g_pairCount; i++)
     {
      g_peakBasketProfit[i] = 0.0;
      g_gridPlaced[i] = false;

      // Ensure symbol is available
      if(!SymbolSelect(g_pairs[i], true))
        {
         PrintFormat("WARNING: Could not select symbol %s — skipping", g_pairs[i]);
         continue;
        }

      // Create MA handle for trend detection
      ENUM_MA_METHOD maMethod = (InpTrendMAMethod == 1) ? MODE_EMA : MODE_SMA;
      g_trendMA_handles[i] = iMA(g_pairs[i], InpTrendTF, InpTrendMAPeriod, 0, maMethod, PRICE_CLOSE);

      if(g_trendMA_handles[i] == INVALID_HANDLE)
         PrintFormat("WARNING: Could not create MA handle for %s", g_pairs[i]);

      // Check if grid is already placed (on restart)
      if(CountPositions(g_pairs[i]) > 0 || CountPendingOrders(g_pairs[i]) > 0)
         g_gridPlaced[i] = true;
     }

   PrintFormat("=== Arbitrage Grid Bot v2.0 Initialized ===");
   PrintFormat("Pairs: %s", InpPairList);
   PrintFormat("Grid: %d pips, Max %d levels, Base lot: %.2f", InpGridSpacingPips, InpMaxGridLevels, InpBaseLotSize);
   PrintFormat("Basket TP: $%.2f | Max DD: %.1f%%", InpBasketTPDollars, InpMaxDrawdownPct);
   PrintFormat("Order Mode: %s", InpUsePendingOrders ? "Pending Limit Orders" : "Market Orders");
   PrintFormat("============================================");

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Release indicator handles
   for(int i = 0; i < g_pairCount; i++)
     {
      if(g_trendMA_handles[i] != INVALID_HANDLE)
         IndicatorRelease(g_trendMA_handles[i]);
     }
   Print("Arbitrage Grid Bot Stopped.");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- EMERGENCY DRAWDOWN CHECK ---
   if(CheckDrawdownLimit())
      return;

   // --- PROCESS EACH PAIR ---
   for(int i = 0; i < g_pairCount; i++)
     {
      string symbol = g_pairs[i];

      // Skip if symbol not available
      if(!SymbolInfoInteger(symbol, SYMBOL_VISIBLE))
         continue;

      // 1. Count filled positions and pending orders
      int posCount = CountPositions(symbol);
      int pendCount = CountPendingOrders(symbol);

      // 2. Calculate basket profit for filled positions
      double basketProfit = GetBasketProfit(symbol);

      // Track peak for potential trailing
      if(basketProfit > g_peakBasketProfit[i])
         g_peakBasketProfit[i] = basketProfit;

      // 3. Check basket take profit — close all positions AND cancel pending orders
      if(posCount > 0 && basketProfit >= InpBasketTPDollars)
        {
         PrintFormat("BASKET TP HIT: %s | Profit: $%.2f | Closing %d positions, cancelling %d pending",
                     symbol, basketProfit, posCount, pendCount);
         CloseBasket(symbol);
         CancelPendingOrders(symbol);
         g_peakBasketProfit[i] = 0.0;
         g_gridPlaced[i] = false;
         continue;
        }

      // 4. Determine trade direction
      int direction = GetTradeDirection(i);
      if(direction == 0)
         continue; // No clear direction

      // 5. Check spread
      if(!IsSpreadAcceptable(symbol))
         continue;

      // 6. Grid entry logic
      if(InpUsePendingOrders)
        {
         // === PENDING ORDER MODE ===
         // Place entire grid of limit orders at once
         if(!g_gridPlaced[i] && posCount == 0 && pendCount == 0)
           {
            PlacePendingGrid(symbol, direction, i);
            g_gridPlaced[i] = true;
           }
        }
      else
        {
         // === MARKET ORDER MODE ===
         if(posCount == 0)
           {
            // No positions — open Level 1
            double lots = CalculateLotSize(1, symbol);
            OpenMarketPosition(symbol, direction, lots, 1);
           }
         else if(posCount < InpMaxGridLevels)
           {
            // Check if price moved enough for next grid level
            if(ShouldAddGridLevel(symbol, direction))
              {
               int nextLevel = posCount + 1;
               double lots = CalculateLotSize(nextLevel, symbol);
               OpenMarketPosition(symbol, direction, lots, nextLevel);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Place entire grid of pending limit orders at once                 |
//+------------------------------------------------------------------+
void PlacePendingGrid(string symbol, int direction, int pairIndex)
  {
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = GetPipSize(symbol);
   double gridStep = InpGridSpacingPips * pipSize;

   // Get stop level (minimum distance for pending orders)
   int stopLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopLevel * point;

   PrintFormat("PLACING GRID: %s | Direction: %s | Levels: %d | Spacing: %d pips",
               symbol, direction == 1 ? "BUY" : "SELL", InpMaxGridLevels, InpGridSpacingPips);

   for(int level = 1; level <= InpMaxGridLevels; level++)
     {
      double lots = CalculateLotSize(level, symbol);
      string comment = StringFormat("%s_L%d", InpTradeComment, level);
      double sl = 0;
      double tp = 0;

      if(direction == 1) // BUY
        {
         // Level 1 = market order at current ask
         // Level 2+ = BUY LIMIT orders below current price
         // Grid goes DOWN: buy at progressively lower (better) prices
         double entryPrice = ask - (level - 1) * gridStep;
         entryPrice = NormalizeDouble(entryPrice, digits);

         // Calculate SL/TP if set
         if(InpIndividualSLPips > 0)
            sl = NormalizeDouble(entryPrice - InpIndividualSLPips * pipSize, digits);
         if(InpIndividualTPPips > 0)
            tp = NormalizeDouble(entryPrice + InpIndividualTPPips * pipSize, digits);

         if(level == 1)
           {
            // Level 1: Market order (immediate entry)
            if(trade.Buy(lots, symbol, ask, sl, tp, comment))
               PrintFormat("  L1 MARKET BUY: %s | %.2f lots @ %.*f", symbol, lots, digits, ask);
            else
               PrintFormat("  L1 BUY FAILED: %s | Error: %d", symbol, GetLastError());
           }
         else
           {
            // Level 2+: Buy Limit (pending order below price)
            if(ask - entryPrice < minDistance)
              {
               // Price too close for pending, skip or adjust
               entryPrice = NormalizeDouble(ask - minDistance - gridStep, digits);
              }

            if(trade.BuyLimit(lots, entryPrice, symbol, sl, tp, ORDER_TIME_GTC, 0, comment))
               PrintFormat("  L%d BUY LIMIT: %s | %.2f lots @ %.*f", level, symbol, lots, digits, entryPrice);
            else
               PrintFormat("  L%d BUY LIMIT FAILED: %s | Error: %d", level, symbol, GetLastError());
           }
        }
      else // SELL
        {
         // Level 1 = market order at current bid
         // Level 2+ = SELL LIMIT orders above current price
         // Grid goes UP: sell at progressively higher (better) prices
         double entryPrice = bid + (level - 1) * gridStep;
         entryPrice = NormalizeDouble(entryPrice, digits);

         // Calculate SL/TP if set
         if(InpIndividualSLPips > 0)
            sl = NormalizeDouble(entryPrice + InpIndividualSLPips * pipSize, digits);
         if(InpIndividualTPPips > 0)
            tp = NormalizeDouble(entryPrice - InpIndividualTPPips * pipSize, digits);

         if(level == 1)
           {
            // Level 1: Market order (immediate entry)
            if(trade.Sell(lots, symbol, bid, sl, tp, comment))
               PrintFormat("  L1 MARKET SELL: %s | %.2f lots @ %.*f", symbol, lots, digits, bid);
            else
               PrintFormat("  L1 SELL FAILED: %s | Error: %d", symbol, GetLastError());
           }
         else
           {
            // Level 2+: Sell Limit (pending order above price)
            if(entryPrice - bid < minDistance)
              {
               entryPrice = NormalizeDouble(bid + minDistance + gridStep, digits);
              }

            if(trade.SellLimit(lots, entryPrice, symbol, sl, tp, ORDER_TIME_GTC, 0, comment))
               PrintFormat("  L%d SELL LIMIT: %s | %.2f lots @ %.*f", level, symbol, lots, digits, entryPrice);
            else
               PrintFormat("  L%d SELL LIMIT FAILED: %s | Error: %d", level, symbol, GetLastError());
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Open a market position (for market order mode)                    |
//+------------------------------------------------------------------+
void OpenMarketPosition(string symbol, int direction, double lots, int level)
  {
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = GetPipSize(symbol);

   double sl = 0;
   double tp = 0;
   string comment = StringFormat("%s_L%d", InpTradeComment, level);

   if(direction == 1)
     {
      if(InpIndividualSLPips > 0) sl = ask - InpIndividualSLPips * pipSize;
      if(InpIndividualTPPips > 0) tp = ask + InpIndividualTPPips * pipSize;

      if(trade.Buy(lots, symbol, ask, sl, tp, comment))
         PrintFormat("GRID BUY: %s | Level %d | Lots: %.2f | Price: %.*f", symbol, level, lots, digits, ask);
      else
         PrintFormat("GRID BUY FAILED: %s | Error: %d", symbol, GetLastError());
     }
   else
     {
      if(InpIndividualSLPips > 0) sl = bid + InpIndividualSLPips * pipSize;
      if(InpIndividualTPPips > 0) tp = bid - InpIndividualTPPips * pipSize;

      if(trade.Sell(lots, symbol, bid, sl, tp, comment))
         PrintFormat("GRID SELL: %s | Level %d | Lots: %.2f | Price: %.*f", symbol, level, lots, digits, bid);
      else
         PrintFormat("GRID SELL FAILED: %s | Error: %d", symbol, GetLastError());
     }
  }

//+------------------------------------------------------------------+
//| Determine trade direction for a pair                              |
//+------------------------------------------------------------------+
int GetTradeDirection(int pairIndex)
  {
   if(g_directions[pairIndex] == 1) return 1;
   if(g_directions[pairIndex] == 2) return 2;

   // AUTO: Use MA trend detection
   if(g_trendMA_handles[pairIndex] == INVALID_HANDLE)
      return 0;

   double maValue[];
   if(CopyBuffer(g_trendMA_handles[pairIndex], 0, 1, 1, maValue) <= 0)
      return 0;

   double close[];
   if(CopyClose(g_pairs[pairIndex], InpTrendTF, 1, 1, close) <= 0)
      return 0;

   if(close[0] > maValue[0]) return 1;
   if(close[0] < maValue[0]) return 2;

   return 0;
  }

//+------------------------------------------------------------------+
//| Check if we should add another grid level (market order mode)     |
//+------------------------------------------------------------------+
bool ShouldAddGridLevel(string symbol, int direction)
  {
   // Find the best entry (the one closest to favorable direction)
   double bestEntry = 0;
   bool found = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(!found)
        {
         bestEntry = openPrice;
         found = true;
        }
      else
        {
         if(direction == 1 && openPrice < bestEntry) bestEntry = openPrice;
         if(direction == 2 && openPrice > bestEntry) bestEntry = openPrice;
        }
     }

   if(!found) return false;

   double currentPrice;
   if(direction == 1)
      currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
   else
      currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);

   double gridDistance = InpGridSpacingPips * GetPipSize(symbol);

   // BUY: price dropped below best (lowest) entry by grid distance
   if(direction == 1 && currentPrice <= bestEntry - gridDistance)
      return true;
   // SELL: price rose above best (highest) entry by grid distance
   if(direction == 2 && currentPrice >= bestEntry + gridDistance)
      return true;

   return false;
  }

//+------------------------------------------------------------------+
//| Calculate lot size for a grid level                               |
//+------------------------------------------------------------------+
double CalculateLotSize(int level, string symbol)
  {
   double lots = InpBaseLotSize;

   switch(InpLotScaleMode)
     {
      case 0: lots = InpBaseLotSize; break;
      case 1: lots = InpBaseLotSize * level; break;
      case 2: lots = InpBaseLotSize * MathPow(2, level - 1); break;
     }

   // Round to volume step using the CORRECT symbol
   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(stepLot > 0)
      lots = MathFloor(lots / stepLot) * stepLot;

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Get pip size for a symbol                                         |
//+------------------------------------------------------------------+
double GetPipSize(string symbol)
  {
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   return (digits == 3 || digits == 5) ? point * 10 : point;
  }

//+------------------------------------------------------------------+
//| Get basket (combined) profit for a symbol                         |
//+------------------------------------------------------------------+
double GetBasketProfit(string symbol)
  {
   double totalProfit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      totalProfit += PositionGetDouble(POSITION_PROFIT)
                   + PositionGetDouble(POSITION_SWAP);
     }

   return totalProfit;
  }

//+------------------------------------------------------------------+
//| Count open positions for a symbol                                 |
//+------------------------------------------------------------------+
int CountPositions(string symbol)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Count pending orders for a symbol                                 |
//+------------------------------------------------------------------+
int CountPendingOrders(string symbol)
  {
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Close all positions for a symbol (basket close)                   |
//+------------------------------------------------------------------+
void CloseBasket(string symbol)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

      trade.PositionClose(ticket);
     }
   PrintFormat("BASKET CLOSED: %s — all positions closed", symbol);
  }

//+------------------------------------------------------------------+
//| Cancel all pending orders for a symbol                            |
//+------------------------------------------------------------------+
void CancelPendingOrders(string symbol)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;

      trade.OrderDelete(ticket);
     }
   PrintFormat("PENDING CANCELLED: %s — all pending orders removed", symbol);
  }

//+------------------------------------------------------------------+
//| Close ALL positions across all pairs (emergency)                  |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   // Close all filled positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      trade.PositionClose(ticket);
     }

   // Cancel all pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      trade.OrderDelete(ticket);
     }

   // Reset grid tracking
   for(int i = 0; i < g_pairCount; i++)
      g_gridPlaced[i] = false;

   Print("EMERGENCY: All positions and pending orders closed!");
  }

//+------------------------------------------------------------------+
//| Check drawdown limit — returns true if limit hit                  |
//+------------------------------------------------------------------+
bool CheckDrawdownLimit()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance <= 0) return false;

   double drawdownPct = ((balance - equity) / balance) * 100.0;

   if(drawdownPct >= InpMaxDrawdownPct)
     {
      PrintFormat("EMERGENCY DRAWDOWN: %.1f%% >= %.1f%% limit — closing all!", drawdownPct, InpMaxDrawdownPct);
      CloseAllPositions();
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Check if spread is acceptable                                     |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable(string symbol)
  {
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double pipSize = GetPipSize(symbol);

   if(pipSize <= 0) return false;

   double spreadPips = (ask - bid) / pipSize;
   return (spreadPips <= InpMaxSpreadPips);
  }

//+------------------------------------------------------------------+
//| Parse comma-separated string into array                           |
//+------------------------------------------------------------------+
int ParseCSV(string csv, string &result[])
  {
   string temp = csv;
   StringReplace(temp, " ", "");

   int count = 0;
   ArrayResize(result, 0);

   while(StringLen(temp) > 0)
     {
      int pos = StringFind(temp, ",");
      string token;

      if(pos >= 0)
        {
         token = StringSubstr(temp, 0, pos);
         temp = StringSubstr(temp, pos + 1);
        }
      else
        {
         token = temp;
         temp = "";
        }

      StringTrimLeft(token);
      StringTrimRight(token);

      if(StringLen(token) > 0)
        {
         count++;
         ArrayResize(result, count);
         result[count - 1] = token;
        }
     }

   return count;
  }
//+------------------------------------------------------------------+
