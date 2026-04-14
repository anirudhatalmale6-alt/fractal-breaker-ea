//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "2.21"
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
// Option 1 = Candle breaks above breaker, then retest of breaker = entry
// Option 2 = Candle close above/below breaker = entry

enum TRADE_DIR   { BOTH_DIRS=0, BUY_ONLY=1, SELL_ONLY=2 };
input TRADE_DIR  TradeDirection   = BOTH_DIRS;    // Trade Direction

input string     _sep4_           = "=== Fractal Settings ===";
input int        FractalBars      = 3;           // Fractal detection bars each side (HTF)
input int        LTF_SwingBars    = 3;           // Swing detection bars each side (LTF breaker)
input int        HTF_LookbackBars = 20;          // HTF bars to look back for fractals
input int        LTF_LookbackBars = 200;         // LTF bars to look back
input int        RaidPips         = 0;           // Min pips price must go beyond fractal (0=any)
input int        SetupExpiryBars  = 0;           // Max LTF bars after raid to enter (0=no limit)

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
   int fractalLTFBar;
};

struct BreakerInfo {
   double level;       // the breaker price level
   double slLevel;     // SL price level
   int breakerBar;     // LTF bar of breaker
};

//--- Arrays
FractalLevel g_htfFractalLows[];
FractalLevel g_htfFractalHighs[];
int g_debugCounter = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v2.10 initialized. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Disabled"),
         " LTF=", EnumToString(LTF_Period));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBar = iTime(Symbol(), LTF_Period, 0);
   if(currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;

   if(CountOpenTrades() >= MaxTrades) return;

   DetectHTFFractals();

   g_debugCounter++;
   if(EnableDebugLog && g_debugCounter % 60 == 1)
   {
      Print("DEBUG FRACTALS: ", ArraySize(g_htfFractalLows), " lows, ",
            ArraySize(g_htfFractalHighs), " highs detected on HTF");
      for(int fi = 0; fi < ArraySize(g_htfFractalLows); fi++)
         Print("  FractalLow[", fi, "] price=", g_htfFractalLows[fi].price,
               " time=", TimeToString(g_htfFractalLows[fi].time));
      for(int fi = 0; fi < ArraySize(g_htfFractalHighs); fi++)
         Print("  FractalHigh[", fi, "] price=", g_htfFractalHighs[fi].price,
               " time=", TimeToString(g_htfFractalHighs[fi].time));
   }

   if(TradeDirection == BOTH_DIRS || TradeDirection == BUY_ONLY)
      CheckBuySetup();
   if(TradeDirection == BOTH_DIRS || TradeDirection == SELL_ONLY)
      CheckSellSetup();
}

//+------------------------------------------------------------------+
void DetectHTFFractals()
{
   ArrayResize(g_htfFractalLows, 0);
   ArrayResize(g_htfFractalHighs, 0);
   DetectFractalsOnTF(HTF_Period_1, FractalBars, 1);
   if(UseHTF2) DetectFractalsOnTF(HTF_Period_2, FractalBars, 2);
}

void DetectFractalsOnTF(ENUM_TIMEFRAMES tf, int nBars, int source)
{
   for(int i = nBars; i < HTF_LookbackBars - nBars; i++)
   {
      double high_i = iHigh(Symbol(), tf, i);
      double low_i  = iLow(Symbol(), tf, i);

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
         g_htfFractalHighs[sz].price = high_i;
         g_htfFractalHighs[sz].time = iTime(Symbol(), tf, i);
         g_htfFractalHighs[sz].barIndex = i;
         g_htfFractalHighs[sz].isHigh = true;
         g_htfFractalHighs[sz].htfSource = source;
         g_htfFractalHighs[sz].tf = tf;
      }

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
         g_htfFractalLows[sz].price = low_i;
         g_htfFractalLows[sz].time = iTime(Symbol(), tf, i);
         g_htfFractalLows[sz].barIndex = i;
         g_htfFractalLows[sz].isHigh = false;
         g_htfFractalLows[sz].htfSource = source;
         g_htfFractalLows[sz].tf = tf;
      }
   }
}

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
//| Check if bar i is a swing HIGH on LTF (local peak)               |
//+------------------------------------------------------------------+
bool IsLTFSwingHigh(int i)
{
   int n = LTF_SwingBars;
   if(i - n < 0 || i + n >= LTF_LookbackBars) return false;

   double high_i = iHigh(Symbol(), LTF_Period, i);

   for(int j = 1; j <= n; j++)
   {
      if(iHigh(Symbol(), LTF_Period, i-j) >= high_i ||
         iHigh(Symbol(), LTF_Period, i+j) >= high_i)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if bar i is a swing LOW on LTF (local trough)              |
//+------------------------------------------------------------------+
bool IsLTFSwingLow(int i)
{
   int n = LTF_SwingBars;
   if(i - n < 0 || i + n >= LTF_LookbackBars) return false;

   double low_i = iLow(Symbol(), LTF_Period, i);

   for(int j = 1; j <= n; j++)
   {
      if(iLow(Symbol(), LTF_Period, i-j) <= low_i ||
         iLow(Symbol(), LTF_Period, i+j) <= low_i)
         return false;
   }
   return true;
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

      // Find raid bar (first LTF bar after fractal that goes below it)
      int raidBar = -1;
      for(int j = fractalLTFBar - 1; j >= 1; j--)
      {
         if(iLow(Symbol(), LTF_Period, j) < fractalPrice - raidThreshold)
         { raidBar = j; break; }
      }
      if(raidBar < 0) continue;
      if(SetupExpiryBars > 0 && raidBar > SetupExpiryBars) continue;

      if(EnableDebugLog)
         Print("DEBUG BUY RAID: Fractal=", fractalPrice,
               " FracLTF=", fractalLTFBar, " RaidBar=", raidBar);

      raid.fractalPrice = fractalPrice;
      raid.fractalTime = fractalTime;
      raid.raidBarLTF = raidBar;
      raid.raidTime = iTime(Symbol(), LTF_Period, raidBar);
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
         { raidBar = j; break; }
      }
      if(raidBar < 0) continue;
      if(SetupExpiryBars > 0 && raidBar > SetupExpiryBars) continue;

      if(EnableDebugLog)
         Print("DEBUG SELL RAID: Fractal=", fractalPrice,
               " FracLTF=", fractalLTFBar, " RaidBar=", raidBar);

      raid.fractalPrice = fractalPrice;
      raid.fractalTime = fractalTime;
      raid.raidBarLTF = raidBar;
      raid.raidTime = iTime(Symbol(), LTF_Period, raidBar);
      raid.fractalLTFBar = fractalLTFBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker for BUY                                      |
//| Breaker = the swing high (local peak) RIGHT BEFORE the drop      |
//| that raided the fractal. Search backwards from raidBar.           |
//| SL = lowest point from breaker down to the raid low               |
//+------------------------------------------------------------------+
bool FindBullishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;

   // Search backwards from raidBar for the first LTF swing high
   // This is the local peak right before the drop started
   for(int i = raidBar + 1; i < LTF_LookbackBars - LTF_SwingBars; i++)
   {
      if(IsLTFSwingHigh(i))
      {
         double breakerLevel = iHigh(Symbol(), LTF_Period, i);

         // SL = lowest point from the breaker to where price reversed
         // (the lowest low between breaker and present)
         double lowestLow = DBL_MAX;
         for(int k = i; k >= 1; k--)
         {
            double lo = iLow(Symbol(), LTF_Period, k);
            if(lo < lowestLow) lowestLow = lo;
            // Stop once price recovered above breaker (we found the bottom)
            if(k < raidBar && iClose(Symbol(), LTF_Period, k) > breakerLevel)
               break;
         }

         brk.level      = breakerLevel;
         brk.slLevel    = lowestLow;
         brk.breakerBar = i;

         if(EnableDebugLog)
            Print("DEBUG BUY BREAKER: Level=", breakerLevel,
                  " at bar ", i, " (", TimeToString(iTime(Symbol(), LTF_Period, i)), ")",
                  " SL=", lowestLow);

         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bearish breaker for SELL                                     |
//| Breaker = the swing low (local trough) RIGHT BEFORE the rally    |
//| that raided the fractal high. Search backwards from raidBar.     |
//| SL = highest point from breaker up to the raid high              |
//+------------------------------------------------------------------+
bool FindBearishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;

   // Search backwards from raidBar for the first LTF swing low
   for(int i = raidBar + 1; i < LTF_LookbackBars - LTF_SwingBars; i++)
   {
      if(IsLTFSwingLow(i))
      {
         double breakerLevel = iLow(Symbol(), LTF_Period, i);

         // SL = highest point from breaker to recovery
         double highestHigh = 0;
         for(int k = i; k >= 1; k--)
         {
            double hi = iHigh(Symbol(), LTF_Period, k);
            if(hi > highestHigh) highestHigh = hi;
            if(k < raidBar && iClose(Symbol(), LTF_Period, k) < breakerLevel)
               break;
         }

         brk.level      = breakerLevel;
         brk.slLevel    = highestHigh;
         brk.breakerBar = i;

         if(EnableDebugLog)
            Print("DEBUG SELL BREAKER: Level=", breakerLevel,
                  " at bar ", i, " (", TimeToString(iTime(Symbol(), LTF_Period, i)), ")",
                  " SL=", highestHigh);

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
   // Step 1: Find raid
   RaidInfo raid;
   if(!FindHTFFractalLowRaid(raid))
   {
      if(EnableDebugLog && g_debugCounter % 60 == 1)
         Print("DEBUG BUY: No HTF fractal low raid found");
      return;
   }

   // Step 2: Find breaker
   BreakerInfo brk;
   if(!FindBullishBreaker(raid, brk))
   {
      if(EnableDebugLog)
         Print("DEBUG BUY: No breaker found for raid at bar ", raid.raidBarLTF);
      return;
   }

   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);
   double bid = MarketInfo(Symbol(), MODE_BID);

   if(EnableDebugLog)
      Print("DEBUG BUY CHECK: BrkLvl=", brk.level,
            " LastClose=", lastClose, " LastLow=", lastLow, " LastOpen=", lastOpen,
            " Ask=", ask);

   bool opt1 = false;
   bool opt2 = false;

   // Option 1: A candle must have ALREADY closed above the breaker level
   // (the initial break), then price retests (comes back to) the breaker = entry
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) > brk.level)
         { hasBroken = true; break; }
      }

      if(EnableDebugLog)
         Print("DEBUG BUY OPT1: hasBroken=", hasBroken,
               " lastLow<=brk=", (lastLow <= brk.level),
               " lastClose>brk=", (lastClose > brk.level),
               " bullish=", (lastClose > lastOpen));

      if(hasBroken)
      {
         if(lastLow <= brk.level && lastClose > brk.level && lastClose > lastOpen)
            opt1 = true;
      }
   }

   // Option 2: Candle closes above breaker level (the first close above it)
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      // Previous candle closed below breaker, this one closes above
      double prevClose = iClose(Symbol(), LTF_Period, 2);

      if(EnableDebugLog)
         Print("DEBUG BUY OPT2: lastClose>brk=", (lastClose > brk.level),
               " prevClose<=brk=", (prevClose <= brk.level),
               " prevClose=", prevClose);

      if(lastClose > brk.level && prevClose <= brk.level)
         opt2 = true;
   }

   if(!opt1 && !opt2) return;

   // SL
   double sl = brk.slLevel - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl >= ask) return;

   // TP
   double slDist = ask - sl;
   double tp = ask + (slDist * RR_Ratio) + MarketInfo(Symbol(), MODE_SPREAD) * Point;

   double lots = CalculateLotSize(slDist, OP_BUY);
   if(lots <= 0) return;

   if(HasTradeAtLevel(brk.level, OP_BUY)) return;

   string comment = "FBE_BUY_OPT" + IntegerToString(opt1 ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_BUY, lots, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      g_lastBuyRaidFractalTime = raid.fractalTime;
      Print("BUY #", ticket, " E=", ask, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (opt1?"1":"2"),
            " BrkLvl=", brk.level, " Frac=", raid.fractalPrice);
   }
   else Print("BUY FAIL: ", GetLastError());
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
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);

   bool opt1 = false;
   bool opt2 = false;

   // Option 1: Candle already broke below, now retesting from below
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) < brk.level)
         { hasBroken = true; break; }
      }

      if(hasBroken)
      {
         if(lastHigh >= brk.level && lastClose < brk.level && lastClose < lastOpen)
            opt1 = true;
      }
   }

   // Option 2: Candle closes below breaker level (first close below it)
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      double prevClose = iClose(Symbol(), LTF_Period, 2);
      if(lastClose < brk.level && prevClose >= brk.level)
         opt2 = true;
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
            " BrkLvl=", brk.level, " Frac=", raid.fractalPrice);
   }
   else Print("SELL FAIL: ", GetLastError());
}

//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance, int orderType)
{
   if(slDistance <= 0) return 0;
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
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
