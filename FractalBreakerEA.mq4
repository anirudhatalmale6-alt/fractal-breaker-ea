//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "1.50"
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
input int        HTF_LookbackBars = 20;          // HTF bars to look back for fractals
input int        LTF_LookbackBars = 200;         // LTF bars to look back
input int        RaidPips         = 0;           // Min pips price must go beyond fractal (0=any)
input int        SetupExpiryBars  = 60;          // Max LTF bars after raid to enter (0=no limit)

input string     _sep5_           = "=== Debug ===";
input bool       EnableDebugLog   = false;       // Print debug info to Experts log

//--- Global variables
datetime g_lastBarTime = 0;

// Track which fractals have already been used for a trade
datetime g_lastBuyRaidFractalTime  = 0;
datetime g_lastSellRaidFractalTime = 0;

//--- Structures
struct FractalLevel {
   double price;
   datetime time;
   int barIndex;
   bool isHigh;
   int htfSource;
   ENUM_TIMEFRAMES tf;
};

struct RaidInfo {
   double fractalPrice;
   datetime fractalTime;
   int raidBarLTF;       // LTF bar where raid happened
   datetime raidTime;
};

struct BreakerBlock {
   double top;
   double bottom;
   double slLevel;
   datetime time;
   int barIndex;
   int swingExtremeBar;
   bool isBullish;
};

//--- Arrays
FractalLevel g_htfFractalLows[];
FractalLevel g_htfFractalHighs[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v1.50 initialized. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Disabled"),
         " LTF=", EnumToString(LTF_Period),
         " SetupExpiry=", SetupExpiryBars);
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
   datetime currentBar = iTime(Symbol(), LTF_Period, 0);
   if(currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;

   if(CountOpenTrades() >= MaxTrades) return;

   DetectHTFFractals();

   if(TradeDirection == BOTH_DIRS || TradeDirection == BUY_ONLY)
      CheckBuySetup();

   if(TradeDirection == BOTH_DIRS || TradeDirection == SELL_ONLY)
      CheckSellSetup();
}

//+------------------------------------------------------------------+
//| Detect fractals on higher timeframes                              |
//+------------------------------------------------------------------+
void DetectHTFFractals()
{
   ArrayResize(g_htfFractalLows, 0);
   ArrayResize(g_htfFractalHighs, 0);

   DetectFractalsOnTF(HTF_Period_1, FractalBars, 1);

   if(UseHTF2)
      DetectFractalsOnTF(HTF_Period_2, FractalBars, 2);
}

//+------------------------------------------------------------------+
//| Detect Williams fractals on a timeframe                           |
//+------------------------------------------------------------------+
void DetectFractalsOnTF(ENUM_TIMEFRAMES tf, int nBars, int source)
{
   for(int i = nBars; i < HTF_LookbackBars - nBars; i++)
   {
      double high_i = iHigh(Symbol(), tf, i);
      double low_i  = iLow(Symbol(), tf, i);

      // Fractal high
      bool isHigh = true;
      for(int j = 1; j <= nBars; j++)
      {
         if(iHigh(Symbol(), tf, i - j) >= high_i || iHigh(Symbol(), tf, i + j) >= high_i)
         { isHigh = false; break; }
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
         g_htfFractalHighs[sz].tf        = tf;
      }

      // Fractal low
      bool isLow = true;
      for(int j = 1; j <= nBars; j++)
      {
         if(iLow(Symbol(), tf, i - j) <= low_i || iLow(Symbol(), tf, i + j) <= low_i)
         { isLow = false; break; }
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
         g_htfFractalLows[sz].tf        = tf;
      }
   }
}

//+------------------------------------------------------------------+
//| Convert HTF bar time to LTF bar index. Returns -1 if out of range|
//+------------------------------------------------------------------+
int HTFTimeToLTFBar(datetime htfTime)
{
   for(int i = 0; i < LTF_LookbackBars; i++)
   {
      if(iTime(Symbol(), LTF_Period, i) <= htfTime)
         return i;
   }
   return -1; // out of LTF range
}

//+------------------------------------------------------------------+
//| Find the most recent valid HTF fractal low raid                   |
//| Requirements:                                                     |
//| - Fractal time must be within LTF lookback range                  |
//| - Raid must occur AFTER fractal formed                            |
//| - Fractal must not have been used for a trade already             |
//| - Raid must be recent enough (within SetupExpiryBars of now)     |
//+------------------------------------------------------------------+
bool FindHTFFractalLowRaid(RaidInfo &raid)
{
   double raidThreshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      double fractalPrice = g_htfFractalLows[i].price;
      datetime fractalTime = g_htfFractalLows[i].time;

      // Skip if already used for a trade
      if(fractalTime == g_lastBuyRaidFractalTime) continue;

      // Convert fractal time to LTF bar index
      int fractalLTFBar = HTFTimeToLTFBar(fractalTime);
      if(fractalLTFBar < 0) continue; // fractal is outside LTF lookback range

      // Look for the FIRST bar after the fractal that goes below it (the raid)
      int raidBar = -1;
      for(int j = fractalLTFBar - 1; j >= 1; j--)
      {
         double lo = iLow(Symbol(), LTF_Period, j);
         if(lo < fractalPrice - raidThreshold)
         {
            raidBar = j;
            break; // found the most recent raid of this fractal
         }
      }

      if(raidBar < 0) continue; // no raid found

      // Check setup expiry - raid must be recent enough
      if(SetupExpiryBars > 0 && raidBar > SetupExpiryBars) continue;

      if(EnableDebugLog)
         Print("DEBUG BUY: Fractal=", fractalPrice, " at ", TimeToString(fractalTime),
               " RaidBar=", raidBar, " LTFbar=", fractalLTFBar);

      raid.fractalPrice = fractalPrice;
      raid.fractalTime  = fractalTime;
      raid.raidBarLTF   = raidBar;
      raid.raidTime     = iTime(Symbol(), LTF_Period, raidBar);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find the most recent valid HTF fractal high raid                  |
//+------------------------------------------------------------------+
bool FindHTFFractalHighRaid(RaidInfo &raid)
{
   double raidThreshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      double fractalPrice = g_htfFractalHighs[i].price;
      datetime fractalTime = g_htfFractalHighs[i].time;

      if(fractalTime == g_lastSellRaidFractalTime) continue;

      int fractalLTFBar = HTFTimeToLTFBar(fractalTime);
      if(fractalLTFBar < 0) continue;

      int raidBar = -1;
      for(int j = fractalLTFBar - 1; j >= 1; j--)
      {
         double hi = iHigh(Symbol(), LTF_Period, j);
         if(hi > fractalPrice + raidThreshold)
         {
            raidBar = j;
            break;
         }
      }

      if(raidBar < 0) continue;

      if(SetupExpiryBars > 0 && raidBar > SetupExpiryBars) continue;

      if(EnableDebugLog)
         Print("DEBUG SELL: Fractal=", fractalPrice, " at ", TimeToString(fractalTime),
               " RaidBar=", raidBar, " LTFbar=", fractalLTFBar);

      raid.fractalPrice = fractalPrice;
      raid.fractalTime  = fractalTime;
      raid.raidBarLTF   = raidBar;
      raid.raidTime     = iTime(Symbol(), LTF_Period, raidBar);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find LTF swing low between raidBar and present                   |
//+------------------------------------------------------------------+
bool FindLTFSwingLowAfterRaid(int raidBar, int &swingBar, double &swingPrice)
{
   int n = LTF_FractalBars;
   // Search from raid towards present for the deepest swing low
   int bestBar = -1;
   double bestPrice = DBL_MAX;

   for(int i = raidBar; i >= n; i--)
   {
      double low_i = iLow(Symbol(), LTF_Period, i);

      bool isLow = true;
      for(int j = 1; j <= n; j++)
      {
         if(i - j < 0 || i + j >= LTF_LookbackBars) { isLow = false; break; }
         if(iLow(Symbol(), LTF_Period, i - j) <= low_i ||
            iLow(Symbol(), LTF_Period, i + j) <= low_i)
         { isLow = false; break; }
      }

      if(isLow && low_i < bestPrice)
      {
         bestBar = i;
         bestPrice = low_i;
      }
   }

   if(bestBar >= 0)
   {
      swingBar   = bestBar;
      swingPrice = bestPrice;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find LTF swing high between raidBar and present                  |
//+------------------------------------------------------------------+
bool FindLTFSwingHighAfterRaid(int raidBar, int &swingBar, double &swingPrice)
{
   int n = LTF_FractalBars;
   int bestBar = -1;
   double bestPrice = 0;

   for(int i = raidBar; i >= n; i--)
   {
      double high_i = iHigh(Symbol(), LTF_Period, i);

      bool isHigh = true;
      for(int j = 1; j <= n; j++)
      {
         if(i - j < 0 || i + j >= LTF_LookbackBars) { isHigh = false; break; }
         if(iHigh(Symbol(), LTF_Period, i - j) >= high_i ||
            iHigh(Symbol(), LTF_Period, i + j) >= high_i)
         { isHigh = false; break; }
      }

      if(isHigh && high_i > bestPrice)
      {
         bestBar = i;
         bestPrice = high_i;
      }
   }

   if(bestBar >= 0)
   {
      swingBar   = bestBar;
      swingPrice = bestPrice;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker block                                        |
//| Breaker = swing HIGH before the swing low that was caused by raid |
//+------------------------------------------------------------------+
bool FindBullishBreaker(int raidBar, BreakerBlock &breaker)
{
   int swingLowBar = 0;
   double swingLowPrice = 0;
   if(!FindLTFSwingLowAfterRaid(raidBar, swingLowBar, swingLowPrice)) return false;

   // Find swing HIGH before the swing low
   int n = LTF_FractalBars;

   for(int i = swingLowBar + 1; i < LTF_LookbackBars - n; i++)
   {
      double high_i = iHigh(Symbol(), LTF_Period, i);

      bool isHigh = true;
      for(int j = 1; j <= n; j++)
      {
         if(i - j < 0 || i + j >= LTF_LookbackBars) { isHigh = false; break; }
         if(iHigh(Symbol(), LTF_Period, i - j) >= high_i ||
            iHigh(Symbol(), LTF_Period, i + j) >= high_i)
         { isHigh = false; break; }
      }

      if(isHigh)
      {
         double candleOpen  = iOpen(Symbol(), LTF_Period, i);
         double candleClose = iClose(Symbol(), LTF_Period, i);
         double candleHigh  = iHigh(Symbol(), LTF_Period, i);

         breaker.top            = candleHigh;
         breaker.bottom         = MathMax(candleOpen, candleClose);
         breaker.slLevel        = swingLowPrice;
         breaker.time           = iTime(Symbol(), LTF_Period, i);
         breaker.barIndex       = i;
         breaker.swingExtremeBar = swingLowBar;
         breaker.isBullish      = true;

         if(EnableDebugLog)
            Print("DEBUG BUY Breaker: ", breaker.bottom, "-", breaker.top,
                  " SwingLow=", swingLowPrice, " at bar ", swingLowBar,
                  " BreakerBar=", i);

         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bearish breaker block                                        |
//+------------------------------------------------------------------+
bool FindBearishBreaker(int raidBar, BreakerBlock &breaker)
{
   int swingHighBar = 0;
   double swingHighPrice = 0;
   if(!FindLTFSwingHighAfterRaid(raidBar, swingHighBar, swingHighPrice)) return false;

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
         { isLow = false; break; }
      }

      if(isLow)
      {
         double candleOpen  = iOpen(Symbol(), LTF_Period, i);
         double candleClose = iClose(Symbol(), LTF_Period, i);
         double candleLow   = iLow(Symbol(), LTF_Period, i);

         breaker.top            = MathMin(candleOpen, candleClose);
         breaker.bottom         = candleLow;
         breaker.slLevel        = swingHighPrice;
         breaker.time           = iTime(Symbol(), LTF_Period, i);
         breaker.barIndex       = i;
         breaker.swingExtremeBar = swingHighBar;
         breaker.isBullish      = false;

         if(EnableDebugLog)
            Print("DEBUG SELL Breaker: ", breaker.bottom, "-", breaker.top,
                  " SwingHigh=", swingHighPrice, " at bar ", swingHighBar,
                  " BreakerBar=", i);

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
   RaidInfo raid;
   if(!FindHTFFractalLowRaid(raid)) return;

   BreakerBlock breaker;
   if(!FindBullishBreaker(raid.raidBarLTF, breaker)) return;

   // Price must have reversed above the breaker after the swing low
   bool priceAbove = false;
   for(int k = breaker.swingExtremeBar - 1; k >= 1; k--)
   {
      if(iClose(Symbol(), LTF_Period, k) > breaker.bottom)
      { priceAbove = true; break; }
   }
   if(!priceAbove) return;

   // Entry conditions on bar 1
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool opt1 = false;
   bool opt2 = false;

   // Option 1: Retest - price was above, came back into breaker zone, bounced
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      bool wasAbove = false;
      for(int k = 2; k < breaker.swingExtremeBar; k++)
      {
         if(iLow(Symbol(), LTF_Period, k) > breaker.bottom)
         { wasAbove = true; break; }
      }
      if(wasAbove && lastLow <= breaker.bottom && lastClose > breaker.bottom && lastClose > lastOpen)
         opt1 = true;
   }

   // Option 2: Candle closes above breaker
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastOpen <= breaker.bottom && lastClose > breaker.bottom)
         opt2 = true;
   }

   if(!opt1 && !opt2) return;

   // SL
   double sl = breaker.slLevel - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl >= ask) return;

   // TP
   double slDist = ask - sl;
   double tp = ask + (slDist * RR_Ratio) + MarketInfo(Symbol(), MODE_SPREAD) * Point;

   // Lot size
   double lots = CalculateLotSize(slDist, OP_BUY);
   if(lots <= 0) return;

   // Duplicate check
   if(HasTradeAtLevel(breaker.bottom, OP_BUY)) return;

   // Place order
   string comment = "FBE_BUY_OPT" + IntegerToString(opt1 ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_BUY, lots, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      // Mark this fractal as used
      g_lastBuyRaidFractalTime = raid.fractalTime;

      Print("BUY #", ticket, " E=", ask, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (opt1 ? "1" : "2"),
            " Brk=", breaker.bottom, "-", breaker.top,
            " Frac=", raid.fractalPrice, " RaidBar=", raid.raidBarLTF);
   }
   else
      Print("BUY FAIL: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Check SELL setup                                                 |
//+------------------------------------------------------------------+
void CheckSellSetup()
{
   RaidInfo raid;
   if(!FindHTFFractalHighRaid(raid)) return;

   BreakerBlock breaker;
   if(!FindBearishBreaker(raid.raidBarLTF, breaker)) return;

   bool priceBelow = false;
   for(int k = breaker.swingExtremeBar - 1; k >= 1; k--)
   {
      if(iClose(Symbol(), LTF_Period, k) < breaker.top)
      { priceBelow = true; break; }
   }
   if(!priceBelow) return;

   double bid = MarketInfo(Symbol(), MODE_BID);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool opt1 = false;
   bool opt2 = false;

   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      bool wasBelow = false;
      for(int k = 2; k < breaker.swingExtremeBar; k++)
      {
         if(iHigh(Symbol(), LTF_Period, k) < breaker.top)
         { wasBelow = true; break; }
      }
      if(wasBelow && lastHigh >= breaker.top && lastClose < breaker.top && lastClose < lastOpen)
         opt1 = true;
   }

   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastOpen >= breaker.top && lastClose < breaker.top)
         opt2 = true;
   }

   if(!opt1 && !opt2) return;

   double sl = breaker.slLevel + MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl <= bid) return;

   double slDist = sl - bid;
   double tp = bid - (slDist * RR_Ratio) - MarketInfo(Symbol(), MODE_SPREAD) * Point;

   double lots = CalculateLotSize(slDist, OP_SELL);
   if(lots <= 0) return;

   if(HasTradeAtLevel(breaker.top, OP_SELL)) return;

   string comment = "FBE_SELL_OPT" + IntegerToString(opt1 ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_SELL, lots, bid, 3, sl, tp, comment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      g_lastSellRaidFractalTime = raid.fractalTime;

      Print("SELL #", ticket, " E=", bid, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (opt1 ? "1" : "2"),
            " Brk=", breaker.bottom, "-", breaker.top,
            " Frac=", raid.fractalPrice, " RaidBar=", raid.raidBarLTF);
   }
   else
      Print("SELL FAIL: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                |
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
//| Count open trades                                                 |
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
//| Check duplicate trade at level                                    |
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
