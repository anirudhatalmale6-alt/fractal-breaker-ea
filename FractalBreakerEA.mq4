//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "3.30"
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
// Option 1 = After candle closes above breaker, wait for retest = entry
// Option 2 = Candle close above breaker = immediate entry

enum TRADE_DIR   { BOTH_DIRS=0, BUY_ONLY=1, SELL_ONLY=2 };
input TRADE_DIR  TradeDirection   = BOTH_DIRS;    // Trade Direction

input string     _sep4_           = "=== Fractal Settings ===";
input int        FractalBars      = 3;           // Fractal detection bars each side (HTF)
input int        HTF_LookbackBars = 50;          // HTF bars to look back for fractals
input int        LTF_LookbackBars = 500;         // LTF bars to look back

input string     _sep5_           = "=== Debug ===";
input bool       EnableDebugLog   = false;       // Print debug info to Journal

//--- Global variables
datetime g_lastBarTime = 0;

// Separate tracking for each option type per direction
// This allows Opt1 and Opt2 to both fire from the same fractal/setup
datetime g_lastBuyOpt1Fractal  = 0;
datetime g_lastBuyOpt2Fractal  = 0;
datetime g_lastSellOpt1Fractal = 0;
datetime g_lastSellOpt2Fractal = 0;

bool     g_debugDumped = false;
int      g_debugCounter = 0;

//--- Structures
struct FractalLevel {
   double price;
   datetime time;
   int barIndex;
   int htfSource;
};

struct RaidInfo {
   double fractalPrice;
   datetime fractalTime;
   int raidBarLTF;       // LTF bar where raid happened (price went below/above fractal)
   int fractalLTFBar;    // LTF bar corresponding to HTF fractal time
};

struct BreakerInfo {
   double level;         // the breaker price level
   double slLevel;       // SL = lowest/highest point the breaker caused
   int breakerBar;       // LTF bar of the breaker
};

FractalLevel g_htfFractalLows[];
FractalLevel g_htfFractalHighs[];

//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v3.30. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Off"),
         " LTF=", EnumToString(LTF_Period),
         " HTF_Lookback=", HTF_LookbackBars,
         " LTF_Lookback=", LTF_LookbackBars,
         " FractalBars=", FractalBars);
   g_debugDumped = false;
   g_debugCounter = 0;
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

   // Debug dump: show all detected fractals once at start
   if(EnableDebugLog && !g_debugDumped)
   {
      g_debugDumped = true;
      DebugDumpFractals();
   }

   if(TradeDirection == BOTH_DIRS || TradeDirection == BUY_ONLY)
      CheckBuySetup();
   if(TradeDirection == BOTH_DIRS || TradeDirection == SELL_ONLY)
      CheckSellSetup();
}

//+------------------------------------------------------------------+
void DebugDumpFractals()
{
   Print("=== FRACTAL DUMP @ ", TimeToString(TimeCurrent()), " ===");
   Print("HTF Fractal LOWS (for BUY raids): ", ArraySize(g_htfFractalLows));
   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      int ltfBar = HTFTimeToLTFBar(g_htfFractalLows[i].time);
      Print("  LOW[", i, "] price=", g_htfFractalLows[i].price,
            " time=", TimeToString(g_htfFractalLows[i].time),
            " htfBar=", g_htfFractalLows[i].barIndex,
            " ltfBar=", ltfBar,
            " src=HTF", g_htfFractalLows[i].htfSource,
            (ltfBar < 0 ? " ***OUTSIDE_LTF_RANGE***" : ""));
   }
   Print("HTF Fractal HIGHS (for SELL raids): ", ArraySize(g_htfFractalHighs));
   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      int ltfBar = HTFTimeToLTFBar(g_htfFractalHighs[i].time);
      Print("  HIGH[", i, "] price=", g_htfFractalHighs[i].price,
            " time=", TimeToString(g_htfFractalHighs[i].time),
            " htfBar=", g_htfFractalHighs[i].barIndex,
            " ltfBar=", ltfBar,
            " src=HTF", g_htfFractalHighs[i].htfSource,
            (ltfBar < 0 ? " ***OUTSIDE_LTF_RANGE***" : ""));
   }
   Print("=== END FRACTAL DUMP ===");
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

      // Fractal HIGH: center bar's high must be strictly higher than all neighbors
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
         g_htfFractalHighs[sz].htfSource = source;
      }

      // Fractal LOW: center bar's low must be strictly lower than all neighbors
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
         g_htfFractalLows[sz].htfSource = source;
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
// Check if a fractal is fully used (both options taken, or the
// relevant option taken in single-option mode)
//+------------------------------------------------------------------+
bool IsBuyRaidFullyUsed(datetime ft)
{
   if(EntryMode == OPTION_1)  return (ft == g_lastBuyOpt1Fractal);
   if(EntryMode == OPTION_2)  return (ft == g_lastBuyOpt2Fractal);
   // BOTH_OPTIONS: fully used only when both have been taken
   return (ft == g_lastBuyOpt1Fractal && ft == g_lastBuyOpt2Fractal);
}

bool IsSellRaidFullyUsed(datetime ft)
{
   if(EntryMode == OPTION_1)  return (ft == g_lastSellOpt1Fractal);
   if(EntryMode == OPTION_2)  return (ft == g_lastSellOpt2Fractal);
   return (ft == g_lastSellOpt1Fractal && ft == g_lastSellOpt2Fractal);
}

//+------------------------------------------------------------------+
//| Find HTF fractal LOW raid (for BUY setups)                       |
//+------------------------------------------------------------------+
bool FindBuyRaid(RaidInfo &raid)
{
   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      double fp = g_htfFractalLows[i].price;
      datetime ft = g_htfFractalLows[i].time;
      if(IsBuyRaidFullyUsed(ft)) continue;

      int fBar = HTFTimeToLTFBar(ft);
      if(fBar < 0)
      {
         if(EnableDebugLog)
            Print("BUY RAID SKIP: Frac=", fp, " @ ", TimeToString(ft),
                  " - outside LTF lookback (", LTF_LookbackBars, " bars)");
         continue;
      }

      // Find raid: scan from fractal towards present
      for(int j = fBar - 1; j >= 1; j--)
      {
         if(iLow(Symbol(), LTF_Period, j) < fp)
         {
            raid.fractalPrice = fp;
            raid.fractalTime = ft;
            raid.raidBarLTF = j;
            raid.fractalLTFBar = fBar;

            if(EnableDebugLog)
               Print("BUY RAID FOUND: Frac=", fp,
                     " @ ", TimeToString(ft),
                     " RaidBar=", j, " (", TimeToString(iTime(Symbol(), LTF_Period, j)), ")");
            return true;
         }
      }

      if(EnableDebugLog)
         Print("BUY RAID MISS: Frac=", fp, " @ ", TimeToString(ft),
               " - no bar dipped below it (scanned LTF bars ", fBar-1, " to 1)");
   }

   if(EnableDebugLog)
   {
      g_debugCounter++;
      if(g_debugCounter % 60 == 1)
         Print("BUY: No raid found. HTF fractal lows count=", ArraySize(g_htfFractalLows));
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find HTF fractal HIGH raid (for SELL setups)                     |
//+------------------------------------------------------------------+
bool FindSellRaid(RaidInfo &raid)
{
   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      double fp = g_htfFractalHighs[i].price;
      datetime ft = g_htfFractalHighs[i].time;
      if(IsSellRaidFullyUsed(ft)) continue;

      int fBar = HTFTimeToLTFBar(ft);
      if(fBar < 0)
      {
         if(EnableDebugLog)
            Print("SELL RAID SKIP: Frac=", fp, " @ ", TimeToString(ft),
                  " - outside LTF lookback");
         continue;
      }

      for(int j = fBar - 1; j >= 1; j--)
      {
         if(iHigh(Symbol(), LTF_Period, j) > fp)
         {
            raid.fractalPrice = fp;
            raid.fractalTime = ft;
            raid.raidBarLTF = j;
            raid.fractalLTFBar = fBar;

            if(EnableDebugLog)
               Print("SELL RAID FOUND: Frac=", fp,
                     " @ ", TimeToString(ft),
                     " RaidBar=", j, " (", TimeToString(iTime(Symbol(), LTF_Period, j)), ")");
            return true;
         }
      }

      if(EnableDebugLog)
         Print("SELL RAID MISS: Frac=", fp, " @ ", TimeToString(ft),
               " - no bar spiked above it");
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker for BUY                                      |
//| = the LOCAL PEAK right before the drop that raided the fractal   |
//| "just on the candles right before the drop starts" (client)      |
//| SL = the lowest point the breaker caused (bottom of the drop)    |
//+------------------------------------------------------------------+
bool FindBullishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;

   // Step 1: Find the lowest low around the raid (this is the SL = bottom of the drop)
   // Search from a few bars before the raid to a few bars after
   double lowestLow = DBL_MAX;
   int slStart = MathMax(1, raidBar - 10);
   int slEnd   = MathMin(raidBar + 5, LTF_LookbackBars - 1);
   for(int i = slStart; i <= slEnd; i++)
   {
      double lo = iLow(Symbol(), LTF_Period, i);
      if(lo < lowestLow) lowestLow = lo;
   }

   // Step 2: Find the LOCAL PEAK before the raid
   // Walk backwards from the raid bar, track the running max high
   // Stop when we've gone 15+ bars past the peak without a new high
   // This finds the peak "right before the drop" not some distant peak
   double highestPrice = 0;
   int highestBar = -1;
   int maxSearch = MathMin(raidBar + LTF_LookbackBars / 2, LTF_LookbackBars - 1);

   for(int i = raidBar; i <= maxSearch; i++)
   {
      double hi = iHigh(Symbol(), LTF_Period, i);
      if(hi > highestPrice)
      {
         highestPrice = hi;
         highestBar = i;
      }

      // If we've gone 15+ bars past the last peak, we've found the local peak
      // This prevents searching too far back into previous swings
      if(highestBar >= 0 && (i - highestBar) >= 15)
         break;
   }

   if(highestBar < 0) return false;

   brk.level = highestPrice;
   brk.slLevel = lowestLow;
   brk.breakerBar = highestBar;

   if(EnableDebugLog)
      Print("BUY BREAKER: Level=", highestPrice,
            " @ bar ", highestBar, " (", TimeToString(iTime(Symbol(), LTF_Period, highestBar)), ")",
            " SL=", lowestLow, " (lowest near raid)");

   return true;
}

//+------------------------------------------------------------------+
//| Find bearish breaker for SELL                                     |
//| = the LOCAL TROUGH right before the spike that raided the fractal|
//+------------------------------------------------------------------+
bool FindBearishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;

   // Step 1: Find the highest high around the raid (SL)
   double highestHigh = 0;
   int slStart = MathMax(1, raidBar - 10);
   int slEnd   = MathMin(raidBar + 5, LTF_LookbackBars - 1);
   for(int i = slStart; i <= slEnd; i++)
   {
      double hi = iHigh(Symbol(), LTF_Period, i);
      if(hi > highestHigh) highestHigh = hi;
   }

   // Step 2: Find the LOCAL TROUGH before the raid
   double lowestPrice = DBL_MAX;
   int lowestBar = -1;
   int maxSearch = MathMin(raidBar + LTF_LookbackBars / 2, LTF_LookbackBars - 1);

   for(int i = raidBar; i <= maxSearch; i++)
   {
      double lo = iLow(Symbol(), LTF_Period, i);
      if(lo < lowestPrice)
      {
         lowestPrice = lo;
         lowestBar = i;
      }

      // 15+ bars past the trough = found it
      if(lowestBar >= 0 && (i - lowestBar) >= 15)
         break;
   }

   if(lowestBar < 0) return false;

   brk.level = lowestPrice;
   brk.slLevel = highestHigh;
   brk.breakerBar = lowestBar;

   if(EnableDebugLog)
      Print("SELL BREAKER: Level=", lowestPrice,
            " @ bar ", lowestBar, " (", TimeToString(iTime(Symbol(), LTF_Period, lowestBar)), ")",
            " SL=", highestHigh, " (highest near raid)");

   return true;
}

//+------------------------------------------------------------------+
//| Check BUY setup                                                  |
//+------------------------------------------------------------------+
void CheckBuySetup()
{
   // Step 1: HTF fractal low must be raided
   RaidInfo raid;
   if(!FindBuyRaid(raid)) return;

   // Step 2: Find breaker (local peak before the raid)
   BreakerInfo brk;
   if(!FindBullishBreaker(raid, brk)) return;

   // Step 3: Entry conditions on bar 1
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);
   double prevClose = iClose(Symbol(), LTF_Period, 2);

   bool opt1 = false;
   bool opt2 = false;

   // Check if this option was already taken for this fractal
   bool opt2AlreadyTaken = (raid.fractalTime == g_lastBuyOpt2Fractal);
   bool opt1AlreadyTaken = (raid.fractalTime == g_lastBuyOpt1Fractal);

   // Option 2: Candle closes above breaker (prev was below) = immediate entry
   if((EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS) && !opt2AlreadyTaken)
   {
      if(lastClose > brk.level && prevClose <= brk.level)
         opt2 = true;

      if(EnableDebugLog)
         Print("BUY OPT2 @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)),
               ": close=", lastClose, " prev=", prevClose,
               " brk=", brk.level, " sig=", opt2,
               " alreadyTaken=", opt2AlreadyTaken);
   }

   // Option 1: After a candle has already closed above breaker,
   // price retests (dips back to breaker) and bounces = entry
   if((EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS) && !opt1AlreadyTaken)
   {
      // Check if price has already broken above the breaker at some point
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) > brk.level)
         { hasBroken = true; break; }
      }

      // Retest: candle's low touches or comes within 3 pips of breaker,
      // but closes above breaker, and is a bullish candle
      double retestTolerance = 3.0 * Point * 10; // 3 pips tolerance for retest
      if(hasBroken && lastLow <= brk.level + retestTolerance &&
         lastClose > brk.level && lastClose > lastOpen)
         opt1 = true;

      if(EnableDebugLog)
         Print("BUY OPT1 @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)),
               ": broken=", hasBroken, " low=", lastLow,
               " close=", lastClose, " open=", lastOpen,
               " brk=", brk.level, " tol=", brk.level + retestTolerance,
               " sig=", opt1, " alreadyTaken=", opt1AlreadyTaken);
   }

   if(!opt1 && !opt2) return;

   // SL with spread buffer
   double sl = brk.slLevel - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl >= ask)
   {
      if(EnableDebugLog) Print("BUY SKIP: SL=", sl, " >= ask=", ask);
      return;
   }

   double slDist = ask - sl;
   double tp = ask + (slDist * RR_Ratio) + MarketInfo(Symbol(), MODE_SPREAD) * Point;

   double lots = CalcLots(slDist);
   if(lots <= 0) return;

   // Determine which option to take (prefer Opt2 if both signal on same bar)
   bool takingOpt1 = opt1 && !opt2;
   bool takingOpt2 = opt2;
   string comment = "FBE_BUY_OPT" + IntegerToString(takingOpt1 ? 1 : 2);

   int ticket = OrderSend(Symbol(), OP_BUY, lots, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      // Mark the specific option as taken for this fractal
      if(takingOpt2) g_lastBuyOpt2Fractal = raid.fractalTime;
      if(takingOpt1) g_lastBuyOpt1Fractal = raid.fractalTime;

      Print("BUY #", ticket, " E=", ask, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (takingOpt1?"1":"2"),
            " Brk=", brk.level, " Frac=", raid.fractalPrice,
            " @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)));
   }
   else Print("BUY FAIL: err=", GetLastError(), " ask=", ask, " sl=", sl, " tp=", tp, " lots=", lots);
}

//+------------------------------------------------------------------+
//| Check SELL setup                                                 |
//+------------------------------------------------------------------+
void CheckSellSetup()
{
   RaidInfo raid;
   if(!FindSellRaid(raid)) return;

   BreakerInfo brk;
   if(!FindBearishBreaker(raid, brk)) return;

   double bid = MarketInfo(Symbol(), MODE_BID);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);
   double prevClose = iClose(Symbol(), LTF_Period, 2);

   bool opt1 = false;
   bool opt2 = false;

   bool opt2AlreadyTaken = (raid.fractalTime == g_lastSellOpt2Fractal);
   bool opt1AlreadyTaken = (raid.fractalTime == g_lastSellOpt1Fractal);

   // Option 2: Candle closes below breaker
   if((EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS) && !opt2AlreadyTaken)
   {
      if(lastClose < brk.level && prevClose >= brk.level)
         opt2 = true;

      if(EnableDebugLog)
         Print("SELL OPT2 @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)),
               ": close=", lastClose, " prev=", prevClose,
               " brk=", brk.level, " sig=", opt2);
   }

   // Option 1: After break below, retest from below
   if((EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS) && !opt1AlreadyTaken)
   {
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) < brk.level)
         { hasBroken = true; break; }
      }

      double retestTolerance = 3.0 * Point * 10;
      if(hasBroken && lastHigh >= brk.level - retestTolerance &&
         lastClose < brk.level && lastClose < lastOpen)
         opt1 = true;

      if(EnableDebugLog)
         Print("SELL OPT1 @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)),
               ": broken=", hasBroken, " high=", lastHigh,
               " close=", lastClose, " open=", lastOpen,
               " brk=", brk.level, " sig=", opt1);
   }

   if(!opt1 && !opt2) return;

   double sl = brk.slLevel + MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl <= bid) return;

   double slDist = sl - bid;
   double tp = bid - (slDist * RR_Ratio) - MarketInfo(Symbol(), MODE_SPREAD) * Point;

   double lots = CalcLots(slDist);
   if(lots <= 0) return;

   bool takingOpt1 = opt1 && !opt2;
   bool takingOpt2 = opt2;
   string comment = "FBE_SELL_OPT" + IntegerToString(takingOpt1 ? 1 : 2);

   int ticket = OrderSend(Symbol(), OP_SELL, lots, bid, 3, sl, tp, comment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      if(takingOpt2) g_lastSellOpt2Fractal = raid.fractalTime;
      if(takingOpt1) g_lastSellOpt1Fractal = raid.fractalTime;

      Print("SELL #", ticket, " E=", bid, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (takingOpt1?"1":"2"),
            " Brk=", brk.level, " Frac=", raid.fractalPrice,
            " @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)));
   }
   else Print("SELL FAIL: err=", GetLastError(), " bid=", bid, " sl=", sl, " tp=", tp, " lots=", lots);
}

//+------------------------------------------------------------------+
double CalcLots(double slDist)
{
   if(slDist <= 0) return 0;
   double tv = MarketInfo(Symbol(), MODE_TICKVALUE);
   double ts = MarketInfo(Symbol(), MODE_TICKSIZE);
   double minL = MarketInfo(Symbol(), MODE_MINLOT);
   double maxL = MarketInfo(Symbol(), MODE_MAXLOT);
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(tv <= 0 || ts <= 0) return minL;

   double ticks = slDist / ts;
   double cost = (ticks * tv) + CommissionPerLot;
   if(cost <= 0) return minL;

   double lots = RiskAmount / cost;
   lots = MathFloor(lots / step) * step;
   if(lots < minL) lots = minL;
   if(lots > maxL) lots = maxL;
   return NormalizeDouble(lots, 2);
}

int CountOpenTrades()
{
   int c = 0;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL) c++;
   }
   return c;
}
//+------------------------------------------------------------------+
