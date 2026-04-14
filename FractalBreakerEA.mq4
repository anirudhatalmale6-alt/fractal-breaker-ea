//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "2.00"
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
// Option 1 = Candle break above breaker, then retest
// Option 2 = Candle close above/below breaker level

enum TRADE_DIR   { BOTH_DIRS=0, BUY_ONLY=1, SELL_ONLY=2 };
input TRADE_DIR  TradeDirection   = BOTH_DIRS;    // Trade Direction

input string     _sep4_           = "=== Fractal Settings ===";
input int        FractalBars      = 3;           // Fractal detection bars each side (HTF)
input int        HTF_LookbackBars = 20;          // HTF bars to look back for fractals
input int        LTF_LookbackBars = 200;         // LTF bars to look back
input int        RaidPips         = 0;           // Min pips price must go beyond fractal (0=any)
input int        SetupExpiryBars  = 60;          // Max LTF bars after raid to enter (0=no limit)

input string     _sep5_           = "=== Debug ===";
input bool       EnableDebugLog   = false;       // Print debug info to Experts log

//--- Global variables
datetime g_lastBarTime = 0;
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
   int raidBarLTF;
   datetime raidTime;
   int fractalLTFBar;    // LTF bar index of the HTF fractal
};

struct BreakerInfo {
   double level;          // the breaker price level (highest/lowest point before raid)
   double slLevel;        // SL level (lowest/highest point caused by the drop/rally)
   int breakerBar;        // LTF bar index of the breaker candle
   int slBar;             // LTF bar index of the SL extreme
};

//--- Arrays
FractalLevel g_htfFractalLows[];
FractalLevel g_htfFractalHighs[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v2.00 initialized. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Disabled"),
         " LTF=", EnumToString(LTF_Period));
   return(INIT_SUCCEEDED);
}

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
         if(iHigh(Symbol(), tf, i-j) >= high_i || iHigh(Symbol(), tf, i+j) >= high_i)
         { isHigh = false; break; }
      }
      if(isHigh)
      {
         int sz = ArraySize(g_htfFractalHighs);
         ArrayResize(g_htfFractalHighs, sz+1);
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
         if(iLow(Symbol(), tf, i-j) <= low_i || iLow(Symbol(), tf, i+j) <= low_i)
         { isLow = false; break; }
      }
      if(isLow)
      {
         int sz = ArraySize(g_htfFractalLows);
         ArrayResize(g_htfFractalLows, sz+1);
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
//| Convert HTF time to LTF bar index (-1 if out of range)           |
//+------------------------------------------------------------------+
int HTFTimeToLTFBar(datetime htfTime)
{
   for(int i = 0; i < LTF_LookbackBars; i++)
   {
      if(iTime(Symbol(), LTF_Period, i) <= htfTime)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Find HTF fractal LOW raid                                         |
//+------------------------------------------------------------------+
bool FindHTFFractalLowRaid(RaidInfo &raid)
{
   double raidThreshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      double fractalPrice = g_htfFractalLows[i].price;
      datetime fractalTime = g_htfFractalLows[i].time;

      if(fractalTime == g_lastBuyRaidFractalTime) continue;

      int fractalLTFBar = HTFTimeToLTFBar(fractalTime);
      if(fractalLTFBar < 0) continue;

      // Find raid: LTF bar AFTER fractal that goes below fractal price
      int raidBar = -1;
      for(int j = fractalLTFBar - 1; j >= 1; j--)
      {
         if(iLow(Symbol(), LTF_Period, j) < fractalPrice - raidThreshold)
         {
            raidBar = j;
            break;
         }
      }
      if(raidBar < 0) continue;

      // Setup expiry
      if(SetupExpiryBars > 0 && raidBar > SetupExpiryBars) continue;

      if(EnableDebugLog)
         Print("DEBUG BUY RAID: Fractal=", fractalPrice, " FracLTF=", fractalLTFBar,
               " RaidBar=", raidBar);

      raid.fractalPrice  = fractalPrice;
      raid.fractalTime   = fractalTime;
      raid.raidBarLTF    = raidBar;
      raid.raidTime      = iTime(Symbol(), LTF_Period, raidBar);
      raid.fractalLTFBar = fractalLTFBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find HTF fractal HIGH raid                                        |
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
         if(iHigh(Symbol(), LTF_Period, j) > fractalPrice + raidThreshold)
         {
            raidBar = j;
            break;
         }
      }
      if(raidBar < 0) continue;

      if(SetupExpiryBars > 0 && raidBar > SetupExpiryBars) continue;

      if(EnableDebugLog)
         Print("DEBUG SELL RAID: Fractal=", fractalPrice, " FracLTF=", fractalLTFBar,
               " RaidBar=", raidBar);

      raid.fractalPrice  = fractalPrice;
      raid.fractalTime   = fractalTime;
      raid.raidBarLTF    = raidBar;
      raid.raidTime      = iTime(Symbol(), LTF_Period, raidBar);
      raid.fractalLTFBar = fractalLTFBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker for BUY                                      |
//| Breaker = HIGHEST PRICE on LTF before the raid                   |
//| SL = LOWEST PRICE between breaker and where price reversed       |
//+------------------------------------------------------------------+
bool FindBullishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int fracBar = raid.fractalLTFBar;
   int raidBar = raid.raidBarLTF;

   // Find the highest high BEFORE the raid
   // Search from fractal bar to raid bar
   double highestPrice = 0;
   int highestBar = -1;

   for(int i = fracBar; i >= raidBar; i--)
   {
      double hi = iHigh(Symbol(), LTF_Period, i);
      if(hi > highestPrice)
      {
         highestPrice = hi;
         highestBar = i;
      }
   }

   if(highestBar < 0) return false;

   // SL = lowest price from the breaker high to where price starts recovering
   // (the lowest point the breaker caused = lowest low from breaker to present)
   double lowestPrice = DBL_MAX;
   int lowestBar = -1;

   for(int i = highestBar; i >= 1; i--)
   {
      double lo = iLow(Symbol(), LTF_Period, i);
      if(lo < lowestPrice)
      {
         lowestPrice = lo;
         lowestBar = i;
      }
      // Stop searching once price has recovered above the breaker
      if(iClose(Symbol(), LTF_Period, i) > highestPrice && i < raidBar)
         break;
   }

   if(lowestBar < 0) return false;

   brk.level      = highestPrice;
   brk.slLevel    = lowestPrice;
   brk.breakerBar = highestBar;
   brk.slBar      = lowestBar;

   if(EnableDebugLog)
      Print("DEBUG BUY BREAKER: Level=", highestPrice, " at bar ", highestBar,
            " SL=", lowestPrice, " at bar ", lowestBar);

   return true;
}

//+------------------------------------------------------------------+
//| Find bearish breaker for SELL                                     |
//| Breaker = LOWEST PRICE on LTF before the raid                   |
//| SL = HIGHEST PRICE between breaker and where price reversed      |
//+------------------------------------------------------------------+
bool FindBearishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int fracBar = raid.fractalLTFBar;
   int raidBar = raid.raidBarLTF;

   // Find the lowest low BEFORE the raid
   double lowestPrice = DBL_MAX;
   int lowestBar = -1;

   for(int i = fracBar; i >= raidBar; i--)
   {
      double lo = iLow(Symbol(), LTF_Period, i);
      if(lo < lowestPrice)
      {
         lowestPrice = lo;
         lowestBar = i;
      }
   }

   if(lowestBar < 0) return false;

   // SL = highest price from the breaker low to where price starts dropping
   double highestPrice = 0;
   int highestBar = -1;

   for(int i = lowestBar; i >= 1; i--)
   {
      double hi = iHigh(Symbol(), LTF_Period, i);
      if(hi > highestPrice)
      {
         highestPrice = hi;
         highestBar = i;
      }
      if(iClose(Symbol(), LTF_Period, i) < lowestPrice && i < raidBar)
         break;
   }

   if(highestBar < 0) return false;

   brk.level      = lowestPrice;
   brk.slLevel    = highestPrice;
   brk.breakerBar = lowestBar;
   brk.slBar      = highestBar;

   if(EnableDebugLog)
      Print("DEBUG SELL BREAKER: Level=", lowestPrice, " at bar ", lowestBar,
            " SL=", highestPrice, " at bar ", highestBar);

   return true;
}

//+------------------------------------------------------------------+
//| Check BUY setup                                                  |
//+------------------------------------------------------------------+
void CheckBuySetup()
{
   // Step 1: Find HTF fractal low raid
   RaidInfo raid;
   if(!FindHTFFractalLowRaid(raid)) return;

   // Step 2: Find breaker (highest point before raid)
   BreakerInfo brk;
   if(!FindBullishBreaker(raid, brk)) return;

   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool opt1 = false;
   bool opt2 = false;

   // Option 1: A candle must have ALREADY broken above the breaker level,
   // then the current candle retests (dips back to it) and bounces
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      // Check if any previous candle closed above the breaker (the break)
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) > brk.level)
         {
            hasBroken = true;
            break;
         }
      }

      if(hasBroken)
      {
         // Retest: current candle dips to/below breaker level but closes above it
         if(lastLow <= brk.level && lastClose > brk.level && lastClose > lastOpen)
         {
            opt1 = true;
         }
      }
   }

   // Option 2: Candle closes above the breaker level
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      // Previous candle was below, this one closes above
      double prevClose = iClose(Symbol(), LTF_Period, 2);
      if(prevClose <= brk.level && lastClose > brk.level)
      {
         opt2 = true;
      }
   }

   if(!opt1 && !opt2) return;

   // SL
   double sl = brk.slLevel - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl >= ask) return;

   // TP
   double slDist = ask - sl;
   double tp = ask + (slDist * RR_Ratio) + MarketInfo(Symbol(), MODE_SPREAD) * Point;

   // Lot size
   double lots = CalculateLotSize(slDist, OP_BUY);
   if(lots <= 0) return;

   // Duplicate check
   if(HasTradeAtLevel(brk.level, OP_BUY)) return;

   // Place order
   string comment = "FBE_BUY_OPT" + IntegerToString(opt1 ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_BUY, lots, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      g_lastBuyRaidFractalTime = raid.fractalTime;
      Print("BUY #", ticket, " E=", ask, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (opt1?"1":"2"),
            " BreakerLvl=", brk.level, " Frac=", raid.fractalPrice);
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

   BreakerInfo brk;
   if(!FindBearishBreaker(raid, brk)) return;

   double bid = MarketInfo(Symbol(), MODE_BID);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool opt1 = false;
   bool opt2 = false;

   // Option 1: A candle already broke below breaker, now retesting from below
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) < brk.level)
         {
            hasBroken = true;
            break;
         }
      }

      if(hasBroken)
      {
         // Retest: candle wicks up to breaker level but closes below
         if(lastHigh >= brk.level && lastClose < brk.level && lastClose < lastOpen)
         {
            opt1 = true;
         }
      }
   }

   // Option 2: Candle closes below breaker level
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      double prevClose = iClose(Symbol(), LTF_Period, 2);
      if(prevClose >= brk.level && lastClose < brk.level)
      {
         opt2 = true;
      }
   }

   if(!opt1 && !opt2) return;

   double sl = brk.slLevel + MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl <= bid) return;

   double slDist = sl - bid;
   double tp = bid - (slDist * RR_Ratio) - MarketInfo(Symbol(), MODE_SPREAD) * Point;

   double lots = CalculateLotSize(slDist, OP_SELL);
   if(lots <= 0) return;

   if(HasTradeAtLevel(brk.level, OP_SELL)) return;

   string comment = "FBE_SELL_OPT" + IntegerToString(opt1 ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_SELL, lots, bid, 3, sl, tp, comment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      g_lastSellRaidFractalTime = raid.fractalTime;
      Print("SELL #", ticket, " E=", bid, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (opt1?"1":"2"),
            " BreakerLvl=", brk.level, " Frac=", raid.fractalPrice);
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
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Duplicate trade check                                             |
//+------------------------------------------------------------------+
bool HasTradeAtLevel(double level, int type)
{
   double tolerance = 10 * Point;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != type) continue;
      if(MathAbs(OrderOpenPrice() - level) < tolerance) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
