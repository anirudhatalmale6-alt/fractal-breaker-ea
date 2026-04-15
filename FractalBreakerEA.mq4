//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "3.40"
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

enum TRADE_DIR   { BOTH_DIRS=0, BUY_ONLY=1, SELL_ONLY=2 };
input TRADE_DIR  TradeDirection   = BOTH_DIRS;    // Trade Direction

input string     _sep4_           = "=== Fractal Settings ===";
input int        FractalBars      = 3;           // Fractal detection bars each side (HTF)
input int        HTF_LookbackBars = 50;          // HTF bars to look back for fractals
input int        LTF_LookbackBars = 500;         // LTF bars to look back
input int        BreakerSearchBars = 50;         // LTF bars before raid to search for breaker

input string     _sep5_           = "=== Debug ===";
input bool       EnableDebugLog   = false;       // Print debug info to Journal

//--- Global variables
datetime g_lastBarTime = 0;

// Separate tracking for Opt1 and Opt2 so both can fire from same setup
datetime g_lastBuyOpt1Fractal  = 0;
datetime g_lastBuyOpt2Fractal  = 0;
datetime g_lastSellOpt1Fractal = 0;
datetime g_lastSellOpt2Fractal = 0;

int g_barCount = 0;

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
   int raidBarLTF;
   int fractalLTFBar;
};

struct BreakerInfo {
   double level;
   double slLevel;
   int breakerBar;
};

FractalLevel g_htfFractalLows[];
FractalLevel g_htfFractalHighs[];

//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v3.40. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Off"),
         " LTF=", EnumToString(LTF_Period),
         " HTF_Lookback=", HTF_LookbackBars,
         " LTF_Lookback=", LTF_LookbackBars,
         " BreakerSearch=", BreakerSearchBars,
         " FractalBars=", FractalBars);
   g_barCount = 0;
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBar = iTime(Symbol(), LTF_Period, 0);
   if(currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;
   g_barCount++;

   if(CountOpenTrades() >= MaxTrades) return;

   DetectHTFFractals();

   // Periodic fractal dump every 100 bars when debug is on
   if(EnableDebugLog && (g_barCount == 1 || g_barCount % 100 == 0))
      DebugDumpFractals();

   // Log bar summary on every bar when debug is on
   if(EnableDebugLog)
      Print("--- BAR #", g_barCount, " @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)),
            " | Lows=", ArraySize(g_htfFractalLows),
            " Highs=", ArraySize(g_htfFractalHighs), " ---");

   if(TradeDirection == BOTH_DIRS || TradeDirection == BUY_ONLY)
      CheckBuySetup();
   if(TradeDirection == BOTH_DIRS || TradeDirection == SELL_ONLY)
      CheckSellSetup();
}

//+------------------------------------------------------------------+
void DebugDumpFractals()
{
   Print("=== FRACTAL DUMP @ ", TimeToString(TimeCurrent()), " (bar #", g_barCount, ") ===");
   Print("HTF Fractal LOWS: ", ArraySize(g_htfFractalLows));
   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      int ltfBar = HTFTimeToLTFBar(g_htfFractalLows[i].time);
      Print("  LOW[", i, "] price=", g_htfFractalLows[i].price,
            " time=", TimeToString(g_htfFractalLows[i].time),
            " htfBar=", g_htfFractalLows[i].barIndex,
            " ltfBar=", ltfBar);
   }
   Print("HTF Fractal HIGHS: ", ArraySize(g_htfFractalHighs));
   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      int ltfBar = HTFTimeToLTFBar(g_htfFractalHighs[i].time);
      Print("  HIGH[", i, "] price=", g_htfFractalHighs[i].price,
            " time=", TimeToString(g_htfFractalHighs[i].time),
            " htfBar=", g_htfFractalHighs[i].barIndex,
            " ltfBar=", ltfBar);
   }
   Print("=== END DUMP ===");
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
         g_htfFractalHighs[sz].htfSource = source;
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
bool IsBuyRaidFullyUsed(datetime ft)
{
   if(EntryMode == OPTION_1)  return (ft == g_lastBuyOpt1Fractal);
   if(EntryMode == OPTION_2)  return (ft == g_lastBuyOpt2Fractal);
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
      if(fBar < 0 || fBar <= 1)
      {
         if(EnableDebugLog)
            Print("  BUY RAID SKIP[", i, "]: frac=", fp, " @ ", TimeToString(ft),
                  " ltfBar=", fBar, (fBar < 0 ? " (outside LTF)" : " (too recent)"));
         continue;
      }

      for(int j = fBar - 1; j >= 1; j--)
      {
         if(iLow(Symbol(), LTF_Period, j) < fp)
         {
            raid.fractalPrice = fp;
            raid.fractalTime = ft;
            raid.raidBarLTF = j;
            raid.fractalLTFBar = fBar;

            if(EnableDebugLog)
               Print("  BUY RAID FOUND: frac=", fp,
                     " @ ", TimeToString(ft),
                     " raidBar=", j, " (", TimeToString(iTime(Symbol(), LTF_Period, j)), ")");
            return true;
         }
      }

      if(EnableDebugLog)
         Print("  BUY RAID MISS[", i, "]: frac=", fp, " @ ", TimeToString(ft),
               " - no bar below it (bars ", fBar-1, " to 1)");
   }
   return false;
}

//+------------------------------------------------------------------+
bool FindSellRaid(RaidInfo &raid)
{
   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      double fp = g_htfFractalHighs[i].price;
      datetime ft = g_htfFractalHighs[i].time;
      if(IsSellRaidFullyUsed(ft)) continue;

      int fBar = HTFTimeToLTFBar(ft);
      if(fBar < 0 || fBar <= 1) continue;

      for(int j = fBar - 1; j >= 1; j--)
      {
         if(iHigh(Symbol(), LTF_Period, j) > fp)
         {
            raid.fractalPrice = fp;
            raid.fractalTime = ft;
            raid.raidBarLTF = j;
            raid.fractalLTFBar = fBar;

            if(EnableDebugLog)
               Print("  SELL RAID FOUND: frac=", fp,
                     " @ ", TimeToString(ft),
                     " raidBar=", j, " (", TimeToString(iTime(Symbol(), LTF_Period, j)), ")");
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker for BUY                                      |
//| = HIGHEST price point before the raid drop                        |
//| SL = lowest point from breaker to recovery above breaker          |
//+------------------------------------------------------------------+
bool FindBullishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;

   // Find the HIGHEST HIGH in BreakerSearchBars bars before the raid
   double highestPrice = 0;
   int highestBar = -1;
   int searchEnd = MathMin(raidBar + BreakerSearchBars, LTF_LookbackBars - 1);

   for(int i = raidBar; i <= searchEnd; i++)
   {
      double hi = iHigh(Symbol(), LTF_Period, i);
      if(hi > highestPrice)
      {
         highestPrice = hi;
         highestBar = i;
      }
   }

   if(highestBar < 0) return false;

   // SL = lowest low from the breaker peak down to where price recovers
   // This captures the entire drop the breaker caused
   double lowestLow = DBL_MAX;
   for(int i = highestBar; i >= 1; i--)
   {
      double lo = iLow(Symbol(), LTF_Period, i);
      if(lo < lowestLow) lowestLow = lo;

      // Stop once price recovers above the breaker level
      if(i < raidBar && iClose(Symbol(), LTF_Period, i) > highestPrice)
         break;
   }

   brk.level = highestPrice;
   brk.slLevel = lowestLow;
   brk.breakerBar = highestBar;

   if(EnableDebugLog)
      Print("  BUY BREAKER: level=", highestPrice,
            " @ bar ", highestBar, " (", TimeToString(iTime(Symbol(), LTF_Period, highestBar)), ")",
            " SL=", lowestLow);

   return true;
}

//+------------------------------------------------------------------+
bool FindBearishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;

   double lowestPrice = DBL_MAX;
   int lowestBar = -1;
   int searchEnd = MathMin(raidBar + BreakerSearchBars, LTF_LookbackBars - 1);

   for(int i = raidBar; i <= searchEnd; i++)
   {
      double lo = iLow(Symbol(), LTF_Period, i);
      if(lo < lowestPrice)
      {
         lowestPrice = lo;
         lowestBar = i;
      }
   }

   if(lowestBar < 0) return false;

   double highestHigh = 0;
   for(int i = lowestBar; i >= 1; i--)
   {
      double hi = iHigh(Symbol(), LTF_Period, i);
      if(hi > highestHigh) highestHigh = hi;

      if(i < raidBar && iClose(Symbol(), LTF_Period, i) < lowestPrice)
         break;
   }

   brk.level = lowestPrice;
   brk.slLevel = highestHigh;
   brk.breakerBar = lowestBar;

   if(EnableDebugLog)
      Print("  SELL BREAKER: level=", lowestPrice,
            " @ bar ", lowestBar, " (", TimeToString(iTime(Symbol(), LTF_Period, lowestBar)), ")",
            " SL=", highestHigh);

   return true;
}

//+------------------------------------------------------------------+
void CheckBuySetup()
{
   RaidInfo raid;
   if(!FindBuyRaid(raid)) return;

   BreakerInfo brk;
   if(!FindBullishBreaker(raid, brk)) return;

   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);
   double prevClose = iClose(Symbol(), LTF_Period, 2);

   bool opt1 = false;
   bool opt2 = false;

   bool opt2Done = (raid.fractalTime == g_lastBuyOpt2Fractal);
   bool opt1Done = (raid.fractalTime == g_lastBuyOpt1Fractal);

   // Option 2: first candle that closes above breaker (prev was below)
   if((EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS) && !opt2Done)
   {
      if(lastClose > brk.level && prevClose <= brk.level)
         opt2 = true;

      if(EnableDebugLog)
         Print("  BUY OPT2: close[1]=", lastClose, " close[2]=", prevClose,
               " brk=", brk.level, " trigger=", opt2, " done=", opt2Done);
   }

   // Option 1: after a candle already closed above breaker,
   // price retests (dips back to) the breaker and bounces
   if((EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS) && !opt1Done)
   {
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) > brk.level)
         { hasBroken = true; break; }
      }

      // Retest: low touches or comes within 3 pips of breaker
      double retestTol = 3.0 * Point * 10;
      if(hasBroken && lastLow <= brk.level + retestTol &&
         lastClose > brk.level && lastClose > lastOpen)
         opt1 = true;

      if(EnableDebugLog)
         Print("  BUY OPT1: broken=", hasBroken, " low[1]=", lastLow,
               " close[1]=", lastClose, " open[1]=", lastOpen,
               " brk=", brk.level, " trigger=", opt1, " done=", opt1Done);
   }

   if(!opt1 && !opt2) return;

   double sl = brk.slLevel - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl >= ask)
   {
      if(EnableDebugLog) Print("  BUY SKIP: SL=", sl, " >= ask=", ask);
      return;
   }

   double slDist = ask - sl;
   double tp = ask + (slDist * RR_Ratio) + MarketInfo(Symbol(), MODE_SPREAD) * Point;
   double lots = CalcLots(slDist);
   if(lots <= 0) return;

   bool takingOpt1 = opt1 && !opt2;
   string comment = "FBE_BUY_OPT" + IntegerToString(takingOpt1 ? 1 : 2);

   int ticket = OrderSend(Symbol(), OP_BUY, lots, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      if(!takingOpt1) g_lastBuyOpt2Fractal = raid.fractalTime;
      else            g_lastBuyOpt1Fractal = raid.fractalTime;

      Print(">>> BUY #", ticket, " Opt", (takingOpt1?"1":"2"),
            " E=", ask, " SL=", sl, " TP=", tp, " L=", lots,
            " Brk=", brk.level, " Frac=", raid.fractalPrice,
            " @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)));
   }
   else Print("!!! BUY FAIL: err=", GetLastError());
}

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

   bool opt2Done = (raid.fractalTime == g_lastSellOpt2Fractal);
   bool opt1Done = (raid.fractalTime == g_lastSellOpt1Fractal);

   if((EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS) && !opt2Done)
   {
      if(lastClose < brk.level && prevClose >= brk.level)
         opt2 = true;

      if(EnableDebugLog)
         Print("  SELL OPT2: close[1]=", lastClose, " close[2]=", prevClose,
               " brk=", brk.level, " trigger=", opt2);
   }

   if((EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS) && !opt1Done)
   {
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) < brk.level)
         { hasBroken = true; break; }
      }

      double retestTol = 3.0 * Point * 10;
      if(hasBroken && lastHigh >= brk.level - retestTol &&
         lastClose < brk.level && lastClose < lastOpen)
         opt1 = true;

      if(EnableDebugLog)
         Print("  SELL OPT1: broken=", hasBroken, " high[1]=", lastHigh,
               " close[1]=", lastClose, " brk=", brk.level, " trigger=", opt1);
   }

   if(!opt1 && !opt2) return;

   double sl = brk.slLevel + MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl <= bid) return;

   double slDist = sl - bid;
   double tp = bid - (slDist * RR_Ratio) - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   double lots = CalcLots(slDist);
   if(lots <= 0) return;

   bool takingOpt1 = opt1 && !opt2;
   string comment = "FBE_SELL_OPT" + IntegerToString(takingOpt1 ? 1 : 2);

   int ticket = OrderSend(Symbol(), OP_SELL, lots, bid, 3, sl, tp, comment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      if(!takingOpt1) g_lastSellOpt2Fractal = raid.fractalTime;
      else            g_lastSellOpt1Fractal = raid.fractalTime;

      Print(">>> SELL #", ticket, " Opt", (takingOpt1?"1":"2"),
            " E=", bid, " SL=", sl, " TP=", tp, " L=", lots,
            " Brk=", brk.level, " Frac=", raid.fractalPrice,
            " @ ", TimeToString(iTime(Symbol(), LTF_Period, 1)));
   }
   else Print("!!! SELL FAIL: err=", GetLastError());
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
