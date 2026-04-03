//+------------------------------------------------------------------+
//|                                           Arbitrage_Grid_Bot.mq5 |
//|                                  Copyright 2026, Antigravity AI  |
//|                              Multi-Pair Statistical Arbitrage Bot |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://github.com/AlessandroGCodeca"
#property version   "1.00"
#property description "Multi-pair grid/DCA arbitrage bot with correlated baskets"

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
input int      InpMinSecBetweenGrid = 30;         // Min seconds between grid entries (same pair)
input int      InpMaxSpreadPips     = 5;          // Max spread (pips) to allow entry

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
datetime       g_lastGridEntryTime[];             // Last grid entry time per pair
double         g_peakBasketProfit[];              // Peak basket profit for trailing

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
   ArrayResize(g_lastGridEntryTime, g_pairCount);
   ArrayResize(g_peakBasketProfit, g_pairCount);
   ArrayResize(g_trendMA_handles, g_pairCount);

   // Validate symbols and create MA handles
   for(int i = 0; i < g_pairCount; i++)
     {
      g_lastGridEntryTime[i] = 0;
      g_peakBasketProfit[i] = 0.0;

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
     }

   PrintFormat("=== Arbitrage Grid Bot Initialized ===");
   PrintFormat("Pairs: %s", InpPairList);
   PrintFormat("Grid: %d pips, Max %d levels, Base lot: %.2f", InpGridSpacingPips, InpMaxGridLevels, InpBaseLotSize);
   PrintFormat("Basket TP: $%.2f | Max DD: %.1f%%", InpBasketTPDollars, InpMaxDrawdownPct);
   PrintFormat("======================================");

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
      return; // All positions closed, skip this tick

   // --- PROCESS EACH PAIR ---
   for(int i = 0; i < g_pairCount; i++)
     {
      string symbol = g_pairs[i];

      // Skip if symbol not available
      if(!SymbolInfoInteger(symbol, SYMBOL_VISIBLE))
         continue;

      // 1. Calculate basket profit for this pair
      double basketProfit = GetBasketProfit(symbol);
      
      // Track peak for potential trailing
      if(basketProfit > g_peakBasketProfit[i])
         g_peakBasketProfit[i] = basketProfit;

      // 2. Check basket take profit
      int posCount = CountPositions(symbol);
      if(posCount > 0 && basketProfit >= InpBasketTPDollars)
        {
         PrintFormat("BASKET TP HIT: %s | Profit: $%.2f | Closing %d positions", symbol, basketProfit, posCount);
         CloseBasket(symbol);
         g_peakBasketProfit[i] = 0.0;
         continue;
        }

      // 3. Determine trade direction
      int direction = GetTradeDirection(i);
      if(direction == 0)
         continue; // No clear direction

      // 4. Check spread
      if(!IsSpreadAcceptable(symbol))
         continue;

      // 5. Grid entry logic
      if(posCount == 0)
        {
         // No positions — open Level 1
         double lots = CalculateLotSize(1);
         OpenGridPosition(symbol, direction, lots, 1);
         g_lastGridEntryTime[i] = TimeCurrent();
        }
      else if(posCount < InpMaxGridLevels)
        {
         // Check if we should add a grid level
         if(ShouldAddGridLevel(symbol, direction, i))
           {
            int nextLevel = posCount + 1;
            double lots = CalculateLotSize(nextLevel);
            OpenGridPosition(symbol, direction, lots, nextLevel);
            g_lastGridEntryTime[i] = TimeCurrent();
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Determine trade direction for a pair                              |
//+------------------------------------------------------------------+
int GetTradeDirection(int pairIndex)
  {
   // If manual direction is set, use it
   if(g_directions[pairIndex] == 1) return 1; // BUY
   if(g_directions[pairIndex] == 2) return 2; // SELL

   // AUTO: Use MA trend detection
   if(g_trendMA_handles[pairIndex] == INVALID_HANDLE)
      return 0;

   double maValue[];
   if(CopyBuffer(g_trendMA_handles[pairIndex], 0, 1, 1, maValue) <= 0)
      return 0;

   // Get current close price on the trend timeframe
   double close[];
   if(CopyClose(g_pairs[pairIndex], InpTrendTF, 1, 1, close) <= 0)
      return 0;

   // Price above MA = BUY trend, below = SELL trend
   if(close[0] > maValue[0])
      return 1; // BUY
   else if(close[0] < maValue[0])
      return 2; // SELL

   return 0; // At MA, no clear direction
  }

//+------------------------------------------------------------------+
//| Check if we should add another grid level                         |
//+------------------------------------------------------------------+
bool ShouldAddGridLevel(string symbol, int direction, int pairIndex)
  {
   // Time gate: don't spam entries
   if(TimeCurrent() - g_lastGridEntryTime[pairIndex] < InpMinSecBetweenGrid)
      return false;

   // Find the worst entry (the one furthest from current price)
   double worstEntry = 0;
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
         worstEntry = openPrice;
         bestEntry = openPrice;
         found = true;
        }
      else
        {
         if(direction == 1) // BUY — worst entry is the highest (bought too high)
           {
            if(openPrice > worstEntry) worstEntry = openPrice;
            if(openPrice < bestEntry)  bestEntry = openPrice;
           }
         else // SELL — worst entry is the lowest (sold too low)
           {
            if(openPrice < worstEntry) worstEntry = openPrice;
            if(openPrice > bestEntry)  bestEntry = openPrice;
           }
        }
     }

   if(!found) return false;

   // Get current price
   double currentPrice;
   if(direction == 1)
      currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
   else
      currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);

   // Calculate grid spacing in price
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;
   double gridDistance = InpGridSpacingPips * pipSize;

   // For BUY: price must have dropped gridDistance below the best (lowest) entry
   // For SELL: price must have risen gridDistance above the best (highest) entry
   if(direction == 1)
     {
      if(currentPrice <= bestEntry - gridDistance)
         return true;
     }
   else
     {
      if(currentPrice >= bestEntry + gridDistance)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Calculate lot size for a grid level                               |
//+------------------------------------------------------------------+
double CalculateLotSize(int level)
  {
   double lots = InpBaseLotSize;

   switch(InpLotScaleMode)
     {
      case 0: // Fixed — same lot every level
         lots = InpBaseLotSize;
         break;
      case 1: // Additive — 0.01, 0.02, 0.03, 0.04...
         lots = InpBaseLotSize * level;
         break;
      case 2: // Multiply — 0.01, 0.02, 0.04, 0.08...
         lots = InpBaseLotSize * MathPow(2, level - 1);
         break;
     }

   // Round to volume step
   double minLot  = SymbolInfoDouble(g_pairs[0], SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(g_pairs[0], SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(g_pairs[0], SYMBOL_VOLUME_STEP);

   if(stepLot > 0)
      lots = MathFloor(lots / stepLot) * stepLot;

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Open a grid position                                              |
//+------------------------------------------------------------------+
void OpenGridPosition(string symbol, int direction, double lots, int level)
  {
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;

   double sl = 0;
   double tp = 0;

   string comment = StringFormat("%s_L%d", InpTradeComment, level);

   if(direction == 1) // BUY
     {
      if(InpIndividualSLPips > 0)
         sl = ask - InpIndividualSLPips * pipSize;
      if(InpIndividualTPPips > 0)
         tp = ask + InpIndividualTPPips * pipSize;

      if(trade.Buy(lots, symbol, ask, sl, tp, comment))
         PrintFormat("GRID BUY: %s | Level %d | Lots: %.2f | Price: %.*f", symbol, level, lots, digits, ask);
      else
         PrintFormat("GRID BUY FAILED: %s | Error: %d", symbol, GetLastError());
     }
   else // SELL
     {
      if(InpIndividualSLPips > 0)
         sl = bid + InpIndividualSLPips * pipSize;
      if(InpIndividualTPPips > 0)
         tp = bid - InpIndividualTPPips * pipSize;

      if(trade.Sell(lots, symbol, bid, sl, tp, comment))
         PrintFormat("GRID SELL: %s | Level %d | Lots: %.2f | Price: %.*f", symbol, level, lots, digits, bid);
      else
         PrintFormat("GRID SELL FAILED: %s | Error: %d", symbol, GetLastError());
     }
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
//| Close ALL positions across all pairs (emergency)                  |
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      trade.PositionClose(ticket);
     }
   Print("EMERGENCY: All positions closed!");
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
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double pipSize = (digits == 3 || digits == 5) ? point * 10 : point;

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
