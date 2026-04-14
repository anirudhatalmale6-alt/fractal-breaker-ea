//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "1.30"
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
// Option 1 = Retest of breaker block (price returns to zone after breaking above/below)
// Option 2 = Candle close above/below breaker block

enum TRADE_DIR   { BOTH_DIRS=0, BUY_ONLY=1, SELL_ONLY=2 };
input TRADE_DIR  TradeDirection   = BOTH_DIRS;    // Trade Direction

input string     _sep4_           = "=== Fractal Settings ===";
input int        FractalBars      = 3;           // Fractal detection bars each side (HTF)
input int        LTF_FractalBars  = 3;           // Fractal detection bars each side (LTF)
input int        HTF_LookbackBars = 100;         // HTF bars to look back for fractals
input int        LTF_LookbackBars = 100;         // LTF bars to look back
input int        RaidPips         = 0;           // Min pips price must go beyond fractal (0=any)

//--- Global variables
datetime g_lastBarTime = 0;

//--- Structures
struct FractalLevel {
   double price;
   datetime time;
   int barIndex;
   bool isHigh;
   int htfSource;
};

struct BreakerBlock {
   double top;           // high of the swing high/low candle
   double bottom;        // body low of the swing high/low candle
   double slLevel;       // the lowest/highest point the breaker caused
   datetime time;
   int barIndex;         // bar index of the breaker (swing high/low candle)
   int swingLowBar;      // bar index of the swing low/high that was taken out
   bool isBullish;
};

//--- Arrays for detected levels
FractalLevel g_htfFractalLows[];
FractalLevel g_htfFractalHighs[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v1.30 initialized. HTF1=", EnumToString(HTF_Period_1),
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
   DetectHTFFractals();

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
void DetectHTFFractals()
{
   ArrayResize(g_htfFractalLows, 0);
   ArrayResize(g_htfFractalHighs, 0);

   DetectFractalsOnTF(HTF_Period_1, FractalBars, 1);

   if(UseHTF2)
   {
      DetectFractalsOnTF(HTF_Period_2, FractalBars, 2);
   }
}

//+------------------------------------------------------------------+
//| Detect Williams-style fractals on a specific timeframe            |
//+------------------------------------------------------------------+
void DetectFractalsOnTF(ENUM_TIMEFRAMES tf, int nBars, int source)
{
   for(int i = nBars; i < HTF_LookbackBars - nBars; i++)
   {
      double high_i = iHigh(Symbol(), tf, i);
      double low_i  = iLow(Symbol(), tf, i);

      // Check fractal high
      bool isHigh = true;
      for(int j = 1; j <= nBars; j++)
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
         int sz = ArraySize(g_htfFractalHighs);
         ArrayResize(g_htfFractalHighs, sz + 1);
         g_htfFractalHighs[sz].price     = high_i;
         g_htfFractalHighs[sz].time      = iTime(Symbol(), tf, i);
         g_htfFractalHighs[sz].barIndex  = i;
         g_htfFractalHighs[sz].isHigh    = true;
         g_htfFractalHighs[sz].htfSource = source;
      }

      // Check fractal low
      bool isLow = true;
      for(int j = 1; j <= nBars; j++)
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
         int sz = ArraySize(g_htfFractalLows);
         ArrayResize(g_htfFractalLows, sz + 1);
         g_htfFractalLows[sz].price     = low_i;
         g_htfFractalLows[sz].time      = iTime(Symbol(), tf, i);
         g_htfFractalLows[sz].barIndex  = i;
         g_htfFractalLows[sz].isHigh    = false;
         g_htfFractalLows[sz].htfSource = source;
      }
   }
}

//+------------------------------------------------------------------+
//| Check if a HTF fractal low was raided on the LTF                 |
//+------------------------------------------------------------------+
bool IsHTFFractalLowRaided(double &raidedLevel)
{
   double raidThreshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      double fractalPrice = g_htfFractalLows[i].price;

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
//| Check if a HTF fractal high was raided on the LTF                |
//+------------------------------------------------------------------+
bool IsHTFFractalHighRaided(double &raidedLevel)
{
   double raidThreshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      double fractalPrice = g_htfFractalHighs[i].price;

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
//| Find a fractal (swing) low on the LTF                            |
//| Returns the most recent swing low                                 |
//+------------------------------------------------------------------+
bool FindLTFSwingLow(int &swingBar, double &swingPrice)
{
   int n = LTF_FractalBars;

   for(int i = n; i < LTF_LookbackBars - n; i++)
   {
      double low_i = iLow(Symbol(), LTF_Period, i);

      bool isLow = true;
      for(int j = 1; j <= n; j++)
      {
         if(iLow(Symbol(), LTF_Period, i - j) <= low_i ||
            iLow(Symbol(), LTF_Period, i + j) <= low_i)
         {
            isLow = false;
            break;
         }
      }

      if(isLow)
      {
         swingBar   = i;
         swingPrice = low_i;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find a fractal (swing) high on the LTF                           |
//| Returns the most recent swing high                                |
//+------------------------------------------------------------------+
bool FindLTFSwingHigh(int &swingBar, double &swingPrice)
{
   int n = LTF_FractalBars;

   for(int i = n; i < LTF_LookbackBars - n; i++)
   {
      double high_i = iHigh(Symbol(), LTF_Period, i);

      bool isHigh = true;
      for(int j = 1; j <= n; j++)
      {
         if(iHigh(Symbol(), LTF_Period, i - j) >= high_i ||
            iHigh(Symbol(), LTF_Period, i + j) >= high_i)
         {
            isHigh = false;
            break;
         }
      }

      if(isHigh)
      {
         swingBar   = i;
         swingPrice = high_i;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker block for BUY setup                         |
//| Breaker = the most recent swing HIGH on LTF that preceded        |
//| the move down which took out the LTF fractal low                  |
//| SL = the lowest point the breaker caused (the swing low)         |
//+------------------------------------------------------------------+
bool FindBullishBreaker(BreakerBlock &breaker)
{
   // Step 1: Find the most recent LTF swing low (fractal low)
   int swingLowBar = 0;
   double swingLowPrice = 0;
   if(!FindLTFSwingLow(swingLowBar, swingLowPrice)) return false;

   // Step 2: Find the most recent swing HIGH that occurred BEFORE this swing low
   // This is the high point from which price dropped to create the swing low
   int n = LTF_FractalBars;

   for(int i = swingLowBar + 1; i < LTF_LookbackBars - n; i++)
   {
      double high_i = iHigh(Symbol(), LTF_Period, i);

      bool isHigh = true;
      for(int j = 1; j <= n; j++)
      {
         // Check bounds
         if(i - j < 0 || i + j >= LTF_LookbackBars) { isHigh = false; break; }

         if(iHigh(Symbol(), LTF_Period, i - j) >= high_i ||
            iHigh(Symbol(), LTF_Period, i + j) >= high_i)
         {
            isHigh = false;
            break;
         }
      }

      if(isHigh)
      {
         // Found the swing high (breaker) that preceded the swing low
         double candleOpen  = iOpen(Symbol(), LTF_Period, i);
         double candleClose = iClose(Symbol(), LTF_Period, i);
         double candleHigh  = iHigh(Symbol(), LTF_Period, i);

         // Breaker zone = the body of the swing high candle
         breaker.top        = candleHigh;
         breaker.bottom     = MathMax(candleOpen, candleClose); // body top
         breaker.slLevel    = swingLowPrice; // SL at the lowest point the breaker caused
         breaker.time       = iTime(Symbol(), LTF_Period, i);
         breaker.barIndex   = i;
         breaker.swingLowBar = swingLowBar;
         breaker.isBullish  = true;

         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bearish breaker block for SELL setup                        |
//| Breaker = the most recent swing LOW on LTF that preceded         |
//| the move up which took out the LTF fractal high                   |
//| SL = the highest point the breaker caused (the swing high)       |
//+------------------------------------------------------------------+
bool FindBearishBreaker(BreakerBlock &breaker)
{
   // Step 1: Find the most recent LTF swing high (fractal high)
   int swingHighBar = 0;
   double swingHighPrice = 0;
   if(!FindLTFSwingHigh(swingHighBar, swingHighPrice)) return false;

   // Step 2: Find the most recent swing LOW that occurred BEFORE this swing high
   int n = LTF_FractalBars;

   for(int i = swingHighBar + 1; i < LTF_LookbackBars - n; i++)
   {
      double low_i = iLow(Symbol(), LTF_Period, i);

      bool isLow = true;
      for(int j = 1; j <= n; j++)
      {
         if(i - j < 0 || i + j >= LTF_LookbackBars) { isLow = false; break; }

         if(iLow(Symbol(), LTF_Period, i - j) <= low_i ||
            iLow(Symbol(), LTF_Period, i + j) <= low_i)
         {
            isLow = false;
            break;
         }
      }

      if(isLow)
      {
         double candleOpen  = iOpen(Symbol(), LTF_Period, i);
         double candleClose = iClose(Symbol(), LTF_Period, i);
         double candleLow   = iLow(Symbol(), LTF_Period, i);

         // Breaker zone = the body of the swing low candle
         breaker.top        = MathMin(candleOpen, candleClose); // body bottom
         breaker.bottom     = candleLow;
         breaker.slLevel    = swingHighPrice; // SL at the highest point the breaker caused
         breaker.time       = iTime(Symbol(), LTF_Period, i);
         breaker.barIndex   = i;
         breaker.swingLowBar = swingHighBar; // reusing field for the swing high bar
         breaker.isBullish  = false;

         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check BUY setup                                                  |
//+------------------------------------------------------------------+
void CheckBuySetup()
{
   double raidedLevel = 0;

   // Step 1: Check if a HTF fractal low was raided
   if(!IsHTFFractalLowRaided(raidedLevel)) return;

   // Step 2: Find bullish breaker block
   BreakerBlock breaker;
   if(!FindBullishBreaker(breaker)) return;

   // Step 3: Verify price has moved above the breaker zone after the swing low
   // (confirms the reversal happened)
   bool priceAboveBreaker = false;
   for(int k = breaker.swingLowBar - 1; k >= 1; k--)
   {
      if(iClose(Symbol(), LTF_Period, k) > breaker.bottom)
      {
         priceAboveBreaker = true;
         break;
      }
   }
   if(!priceAboveBreaker) return;

   // Step 4: Check entry conditions on the last closed candle (bar 1)
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool option1_signal = false;
   bool option2_signal = false;

   // Option 1: RETEST - Price came back down to the breaker zone and bounced
   // Candle wick touched/entered the breaker zone, closed above it
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      // Check that a candle before bar 1 was above the breaker (true retest from above)
      bool wasAbove = false;
      for(int k = 2; k < breaker.swingLowBar; k++)
      {
         if(iLow(Symbol(), LTF_Period, k) > breaker.bottom)
         {
            wasAbove = true;
            break;
         }
      }

      if(wasAbove)
      {
         // Retest: candle dipped into breaker zone but closed above it
         if(lastLow <= breaker.bottom && lastClose > breaker.bottom && lastClose > lastOpen)
         {
            option1_signal = true;
         }
      }
   }

   // Option 2: Candle closes above the breaker zone
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastOpen <= breaker.bottom && lastClose > breaker.bottom)
      {
         option2_signal = true;
      }
   }

   if(!option1_signal && !option2_signal) return;

   // Step 5: SL = the lowest point the breaker caused (the swing low)
   double sl = breaker.slLevel;
   sl = sl - MarketInfo(Symbol(), MODE_SPREAD) * Point; // spread buffer

   if(sl >= ask) return; // invalid SL

   // Step 6: Calculate TP based on RR
   double slDistance = ask - sl;
   double spreadCost = MarketInfo(Symbol(), MODE_SPREAD) * Point;
   double tp = ask + (slDistance * RR_Ratio) + spreadCost;

   // Step 7: Calculate lot size based on risk
   double lotSize = CalculateLotSize(slDistance, OP_BUY);
   if(lotSize <= 0) return;

   // Step 8: Check for duplicate trade at same breaker
   if(HasTradeAtLevel(breaker.bottom, OP_BUY)) return;

   // Step 9: Place the order
   string comment = "FBE_BUY_OPT" + IntegerToString(option1_signal ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_BUY, lotSize, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      Print("BUY #", ticket, " Entry=", ask, " SL=", sl, " TP=", tp,
            " Lots=", lotSize, " Opt=", (option1_signal ? "1" : "2"),
            " Breaker=", breaker.bottom, "-", breaker.top);
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

   // Step 1: Check if a HTF fractal high was raided
   if(!IsHTFFractalHighRaided(raidedLevel)) return;

   // Step 2: Find bearish breaker block
   BreakerBlock breaker;
   if(!FindBearishBreaker(breaker)) return;

   // Step 3: Verify price has moved below the breaker zone after the swing high
   bool priceBelowBreaker = false;
   for(int k = breaker.swingLowBar - 1; k >= 1; k--)
   {
      if(iClose(Symbol(), LTF_Period, k) < breaker.top)
      {
         priceBelowBreaker = true;
         break;
      }
   }
   if(!priceBelowBreaker) return;

   // Step 4: Check entry conditions on bar 1
   double bid = MarketInfo(Symbol(), MODE_BID);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool option1_signal = false;
   bool option2_signal = false;

   // Option 1: RETEST - Price came back up to the breaker zone and got rejected
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      bool wasBelow = false;
      for(int k = 2; k < breaker.swingLowBar; k++)
      {
         if(iHigh(Symbol(), LTF_Period, k) < breaker.top)
         {
            wasBelow = true;
            break;
         }
      }

      if(wasBelow)
      {
         // Retest: candle wicked into breaker zone but closed below it
         if(lastHigh >= breaker.top && lastClose < breaker.top && lastClose < lastOpen)
         {
            option1_signal = true;
         }
      }
   }

   // Option 2: Candle closes below the breaker zone
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastOpen >= breaker.top && lastClose < breaker.top)
      {
         option2_signal = true;
      }
   }

   if(!option1_signal && !option2_signal) return;

   // Step 5: SL = the highest point the breaker caused (the swing high)
   double sl = breaker.slLevel;
   sl = sl + MarketInfo(Symbol(), MODE_SPREAD) * Point; // spread buffer

   if(sl <= bid) return; // invalid SL

   // Step 6: Calculate TP based on RR
   double slDistance = sl - bid;
   double spreadCost = MarketInfo(Symbol(), MODE_SPREAD) * Point;
   double tp = bid - (slDistance * RR_Ratio) - spreadCost;

   // Step 7: Calculate lot size based on risk
   double lotSize = CalculateLotSize(slDistance, OP_SELL);
   if(lotSize <= 0) return;

   // Step 8: Check for duplicate trade at same breaker
   if(HasTradeAtLevel(breaker.top, OP_SELL)) return;

   // Step 9: Place the order
   string comment = "FBE_SELL_OPT" + IntegerToString(option1_signal ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_SELL, lotSize, bid, 3, sl, tp, comment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      Print("SELL #", ticket, " Entry=", bid, " SL=", sl, " TP=", tp,
            " Lots=", lotSize, " Opt=", (option1_signal ? "1" : "2"),
            " Breaker=", breaker.bottom, "-", breaker.top);
   }
   else
   {
      Print("SELL OrderSend failed: ", GetLastError());
   }
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

   double slTicks = slDistance / tickSize;

   double costPerLot = (slTicks * tickValue) + CommissionPerLot;
   if(costPerLot <= 0) return minLot;

   double lots = RiskAmount / costPerLot;

   lots = MathFloor(lots / lotStep) * lotStep;

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
