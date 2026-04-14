//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "1.10"
#property strict

//--- Input Parameters
input string     _sep1_           = "=== Trade Settings ===";
input double     RiskAmount       = 10.0;        // Risk per trade (money amount)
input double     RR_Ratio         = 2.0;         // Risk:Reward Ratio (e.g. 2.0 = 1:2)
input double     CommissionPerLot = 7.0;         // Commission per lot (round-trip, account currency)
input int        MaxTrades        = 2;           // Max simultaneous trades
input int        MagicNumber      = 123456;      // Magic Number

input string     _sep2_           = "=== Timeframe Settings ===";
input ENUM_TIMEFRAMES HTF_Period_1 = PERIOD_M15;  // Higher Timeframe 1 (Fractal Detection)
input bool       UseHTF2          = false;        // Enable second Higher Timeframe?
input ENUM_TIMEFRAMES HTF_Period_2 = PERIOD_M5;   // Higher Timeframe 2 (Fractal Detection)
input ENUM_TIMEFRAMES LTF_Period   = PERIOD_M1;   // Lower Timeframe (Breaker Block Entry)

input string     _sep3_           = "=== Entry Settings ===";
enum ENTRY_MODE  { OPTION_1=0, OPTION_2=1, BOTH_OPTIONS=2 };
input ENTRY_MODE EntryMode        = BOTH_OPTIONS; // Entry Mode
// Option 1 = Retest of breaker block
// Option 2 = Candle close above/below breaker

enum TRADE_DIR   { BOTH_DIRS=0, BUY_ONLY=1, SELL_ONLY=2 };
input TRADE_DIR  TradeDirection   = BOTH_DIRS;    // Trade Direction

input string     _sep4_           = "=== Fractal Settings ===";
input int        FractalBars      = 3;           // Fractal detection bars each side
input int        HTF_LookbackBars = 100;         // HTF bars to look back for fractals
input int        LTF_LookbackBars = 50;          // LTF bars to look back for breaker blocks
input int        RaidPips         = 0;           // Min pips price must go beyond fractal (0=any)

//--- Global variables
datetime g_lastBarTime = 0;

//--- Structures
struct FractalLevel {
   double price;
   datetime time;
   int barIndex;
   bool isHigh;          // true=fractal high, false=fractal low
   int htfSource;        // 1 or 2 (which HTF detected it)
};

struct BreakerBlock {
   double top;
   double bottom;
   datetime time;
   int barIndex;
   bool isBullish;       // true = bullish breaker (looking for buys)
};

//--- Arrays for detected levels
FractalLevel g_fractalLows[];
FractalLevel g_fractalHighs[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v1.10 initialized. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Disabled"),
         " LTF=", EnumToString(LTF_Period));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("FractalBreakerEA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Only process on new LTF bar
   datetime currentBar = iTime(Symbol(), LTF_Period, 0);
   if(currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;

   // Check max trades
   if(CountOpenTrades() >= MaxTrades) return;

   // Step 1: Detect fractals on higher timeframe(s)
   DetectAllFractals();

   // Check for BUY setups
   if(TradeDirection == BOTH_DIRS || TradeDirection == BUY_ONLY)
   {
      CheckBuySetup();
   }

   // Check for SELL setups
   if(TradeDirection == BOTH_DIRS || TradeDirection == SELL_ONLY)
   {
      CheckSellSetup();
   }
}

//+------------------------------------------------------------------+
//| Detect fractals on all enabled higher timeframes                  |
//+------------------------------------------------------------------+
void DetectAllFractals()
{
   ArrayResize(g_fractalLows, 0);
   ArrayResize(g_fractalHighs, 0);

   // Detect on HTF 1
   DetectFractalsOnTF(HTF_Period_1, 1);

   // Detect on HTF 2 if enabled
   if(UseHTF2)
   {
      DetectFractalsOnTF(HTF_Period_2, 2);
   }
}

//+------------------------------------------------------------------+
//| Detect Williams-style fractals on a specific timeframe            |
//+------------------------------------------------------------------+
void DetectFractalsOnTF(ENUM_TIMEFRAMES tf, int source)
{
   int n = FractalBars;

   for(int i = n; i < HTF_LookbackBars - n; i++)
   {
      double high_i = iHigh(Symbol(), tf, i);
      double low_i  = iLow(Symbol(), tf, i);

      // Check fractal high
      bool isHigh = true;
      for(int j = 1; j <= n; j++)
      {
         if(iHigh(Symbol(), tf, i - j) >= high_i ||
            iHigh(Symbol(), tf, i + j) >= high_i)
         {
            isHigh = false;
            break;
         }
      }
      if(isHigh)
      {
         int sz = ArraySize(g_fractalHighs);
         ArrayResize(g_fractalHighs, sz + 1);
         g_fractalHighs[sz].price     = high_i;
         g_fractalHighs[sz].time      = iTime(Symbol(), tf, i);
         g_fractalHighs[sz].barIndex  = i;
         g_fractalHighs[sz].isHigh    = true;
         g_fractalHighs[sz].htfSource = source;
      }

      // Check fractal low
      bool isLow = true;
      for(int j = 1; j <= n; j++)
      {
         if(iLow(Symbol(), tf, i - j) <= low_i ||
            iLow(Symbol(), tf, i + j) <= low_i)
         {
            isLow = false;
            break;
         }
      }
      if(isLow)
      {
         int sz = ArraySize(g_fractalLows);
         ArrayResize(g_fractalLows, sz + 1);
         g_fractalLows[sz].price     = low_i;
         g_fractalLows[sz].time      = iTime(Symbol(), tf, i);
         g_fractalLows[sz].barIndex  = i;
         g_fractalLows[sz].isHigh    = false;
         g_fractalLows[sz].htfSource = source;
      }
   }
}

//+------------------------------------------------------------------+
//| Check if a fractal low was raided (swept) - for BUY setup        |
//| Raid = price goes below the fractal. No recovery needed.         |
//+------------------------------------------------------------------+
bool IsFractalLowRaided(double &raidedLevel)
{
   double raidThreshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_fractalLows); i++)
   {
      double fractalPrice = g_fractalLows[i].price;

      // Check if any recent LTF candle went below the fractal (raided it)
      for(int j = 1; j <= LTF_LookbackBars; j++)
      {
         double lo = iLow(Symbol(), LTF_Period, j);

         if(lo < fractalPrice - raidThreshold)
         {
            raidedLevel = fractalPrice;
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if a fractal high was raided (swept) - for SELL setup      |
//| Raid = price goes above the fractal. No recovery needed.         |
//+------------------------------------------------------------------+
bool IsFractalHighRaided(double &raidedLevel)
{
   double raidThreshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_fractalHighs); i++)
   {
      double fractalPrice = g_fractalHighs[i].price;

      for(int j = 1; j <= LTF_LookbackBars; j++)
      {
         double hi = iHigh(Symbol(), LTF_Period, j);

         if(hi > fractalPrice + raidThreshold)
         {
            raidedLevel = fractalPrice;
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker block on LTF (for BUY entries)              |
//| Breaker = last bearish candle before bullish displacement         |
//+------------------------------------------------------------------+
bool FindBullishBreaker(BreakerBlock &breaker)
{
   for(int i = 2; i < LTF_LookbackBars - 1; i++)
   {
      double open_i  = iOpen(Symbol(), LTF_Period, i);
      double close_i = iClose(Symbol(), LTF_Period, i);

      // Candle i must be bearish
      if(close_i >= open_i) continue;

      // The candle after it must be bullish and close above the bearish candle's open
      double close_after = iClose(Symbol(), LTF_Period, i - 1);
      double open_after  = iOpen(Symbol(), LTF_Period, i - 1);

      if(close_after <= open_after) continue; // must be bullish
      if(close_after <= open_i) continue;     // must close above breaker high

      // Valid bullish breaker found
      breaker.top       = open_i;   // bearish candle open = top of breaker
      breaker.bottom    = close_i;  // bearish candle close = bottom of breaker
      breaker.time      = iTime(Symbol(), LTF_Period, i);
      breaker.barIndex  = i;
      breaker.isBullish = true;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bearish breaker block on LTF (for SELL entries)             |
//| Breaker = last bullish candle before bearish displacement        |
//+------------------------------------------------------------------+
bool FindBearishBreaker(BreakerBlock &breaker)
{
   for(int i = 2; i < LTF_LookbackBars - 1; i++)
   {
      double open_i  = iOpen(Symbol(), LTF_Period, i);
      double close_i = iClose(Symbol(), LTF_Period, i);

      // Candle i must be bullish
      if(close_i <= open_i) continue;

      // The candle after must be bearish and close below the bullish candle's open
      double close_after = iClose(Symbol(), LTF_Period, i - 1);
      double open_after  = iOpen(Symbol(), LTF_Period, i - 1);

      if(close_after >= open_after) continue; // must be bearish
      if(close_after >= open_i) continue;     // must close below breaker low

      // Valid bearish breaker found
      breaker.top       = close_i;  // bullish candle close = top of breaker
      breaker.bottom    = open_i;   // bullish candle open = bottom of breaker
      breaker.time      = iTime(Symbol(), LTF_Period, i);
      breaker.barIndex  = i;
      breaker.isBullish = false;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check BUY setup                                                  |
//+------------------------------------------------------------------+
void CheckBuySetup()
{
   double raidedLevel = 0;

   // Step 1: Check if a fractal low was raided
   if(!IsFractalLowRaided(raidedLevel)) return;

   // Step 2: Find bullish breaker block
   BreakerBlock breaker;
   if(!FindBullishBreaker(breaker)) return;

   // Step 3: Check entry conditions based on option mode
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool option1_signal = false;
   bool option2_signal = false;

   // Option 1: Price retests the breaker block (pulls back into it)
   // Last candle touched or entered the breaker zone and bounced
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      if(lastLow <= breaker.top && lastClose > breaker.top && lastClose > lastOpen)
      {
         option1_signal = true;
      }
   }

   // Option 2: Candle closes above the breaker block
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastClose > breaker.top && lastOpen < breaker.top)
      {
         option2_signal = true;
      }
   }

   if(!option1_signal && !option2_signal) return;

   // Step 4: Calculate SL - lowest point between breaker and entry candle
   double sl = FindLowestBetween(breaker.barIndex, 1);
   sl = sl - MarketInfo(Symbol(), MODE_SPREAD) * Point; // add spread buffer

   if(sl >= ask) return; // invalid SL

   // Step 5: Calculate TP based on RR
   double slDistance = ask - sl;
   double spreadCost = MarketInfo(Symbol(), MODE_SPREAD) * Point;
   double tp = ask + (slDistance * RR_Ratio) + spreadCost;

   // Step 6: Calculate lot size based on risk
   double lotSize = CalculateLotSize(slDistance, OP_BUY);
   if(lotSize <= 0) return;

   // Step 7: Check for duplicate trade at same breaker
   if(HasTradeAtLevel(breaker.top, OP_BUY)) return;

   // Step 8: Place the order
   string comment = "FBE_BUY_OPT" + IntegerToString(option1_signal ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_BUY, lotSize, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      Print("BUY opened #", ticket, " Entry=", ask, " SL=", sl, " TP=", tp,
            " Lots=", lotSize, " Option=", (option1_signal ? "1" : "2"));
   }
   else
   {
      Print("BUY OrderSend failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Check SELL setup                                                 |
//+------------------------------------------------------------------+
void CheckSellSetup()
{
   double raidedLevel = 0;

   // Step 1: Check if a fractal high was raided
   if(!IsFractalHighRaided(raidedLevel)) return;

   // Step 2: Find bearish breaker block
   BreakerBlock breaker;
   if(!FindBearishBreaker(breaker)) return;

   // Step 3: Check entry conditions
   double bid = MarketInfo(Symbol(), MODE_BID);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool option1_signal = false;
   bool option2_signal = false;

   // Option 1: Price retests the breaker block (pulls back into it) and gets rejected
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      if(lastHigh >= breaker.bottom && lastClose < breaker.bottom && lastClose < lastOpen)
      {
         option1_signal = true;
      }
   }

   // Option 2: Candle closes below the breaker block
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastClose < breaker.bottom && lastOpen > breaker.bottom)
      {
         option2_signal = true;
      }
   }

   if(!option1_signal && !option2_signal) return;

   // Step 4: Calculate SL - highest point between breaker and entry candle
   double sl = FindHighestBetween(breaker.barIndex, 1);
   sl = sl + MarketInfo(Symbol(), MODE_SPREAD) * Point; // add spread buffer

   if(sl <= bid) return; // invalid SL

   // Step 5: Calculate TP based on RR
   double slDistance = sl - bid;
   double spreadCost = MarketInfo(Symbol(), MODE_SPREAD) * Point;
   double tp = bid - (slDistance * RR_Ratio) - spreadCost;

   // Step 6: Calculate lot size based on risk
   double lotSize = CalculateLotSize(slDistance, OP_SELL);
   if(lotSize <= 0) return;

   // Step 7: Check for duplicate trade at same breaker
   if(HasTradeAtLevel(breaker.bottom, OP_SELL)) return;

   // Step 8: Place the order
   string comment = "FBE_SELL_OPT" + IntegerToString(option1_signal ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_SELL, lotSize, bid, 3, sl, tp, comment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      Print("SELL opened #", ticket, " Entry=", bid, " SL=", sl, " TP=", tp,
            " Lots=", lotSize, " Option=", (option1_signal ? "1" : "2"));
   }
   else
   {
      Print("SELL OrderSend failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Find lowest low between two bar indices on LTF                   |
//+------------------------------------------------------------------+
double FindLowestBetween(int fromBar, int toBar)
{
   double lowest = iLow(Symbol(), LTF_Period, fromBar);

   for(int i = fromBar; i >= toBar; i--)
   {
      double lo = iLow(Symbol(), LTF_Period, i);
      if(lo < lowest) lowest = lo;
   }
   return lowest;
}

//+------------------------------------------------------------------+
//| Find highest high between two bar indices on LTF                 |
//+------------------------------------------------------------------+
double FindHighestBetween(int fromBar, int toBar)
{
   double highest = iHigh(Symbol(), LTF_Period, fromBar);

   for(int i = fromBar; i >= toBar; i--)
   {
      double hi = iHigh(Symbol(), LTF_Period, i);
      if(hi > highest) highest = hi;
   }
   return highest;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk amount and SL distance          |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance, int orderType)
{
   if(slDistance <= 0) return 0;

   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double minLot    = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot    = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep   = MarketInfo(Symbol(), MODE_LOTSTEP);

   if(tickValue <= 0 || tickSize <= 0) return minLot;

   // SL in ticks
   double slTicks = slDistance / tickSize;

   // lots = RiskAmount / (slTicks * tickValue + CommissionPerLot)
   double costPerLot = (slTicks * tickValue) + CommissionPerLot;
   if(costPerLot <= 0) return minLot;

   double lots = RiskAmount / costPerLot;

   // Round to lot step
   lots = MathFloor(lots / lotStep) * lotStep;

   // Clamp
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Count open trades with our magic number                          |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if we already have a trade at approximately this level     |
//+------------------------------------------------------------------+
bool HasTradeAtLevel(double level, int type)
{
   double tolerance = 10 * Point;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != type) continue;

      if(MathAbs(OrderOpenPrice() - level) < tolerance)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
