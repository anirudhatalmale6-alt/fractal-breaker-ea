//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "3.50"
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
input int        LTF_SwingBars    = 2;           // LTF swing detection bars each side (M1)

input string     _sep5_           = "=== Debug ===";
input bool       EnableDebugLog   = false;       // Print debug info to Journal

//--- Global variables
datetime g_lastBarTime = 0;
datetime g_lastBuyOpt1Fractal  = 0;
datetime g_lastBuyOpt2Fractal  = 0;
datetime g_lastSellOpt1Fractal = 0;
datetime g_lastSellOpt2Fractal = 0;
int      g_barCount = 0;

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
   Print("FractalBreakerEA v3.50. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Off"),
         " LTF=", EnumToString(LTF_Period),
         " HTF_Lookback=", HTF_LookbackBars,
         " LTF_Lookback=", LTF_LookbackBars,
         " FractalBars=", FractalBars,
         " LTF_SwingBars=", LTF_SwingBars);
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

   // Periodic fractal dump
   if(EnableDebugLog && (g_barCount == 1 || g_barCount % 100 == 0))
      DebugDumpFractals();

   if(TradeDirection == BOTH_DIRS || TradeDirection == BUY_ONLY)
      CheckBuySetup();
   if(TradeDirection == BOTH_DIRS || TradeDirection == SELL_ONLY)
      CheckSellSetup();
}

//+------------------------------------------------------------------+
void DebugDumpFractals()
{
   Print("=== FRACTAL DUMP bar#", g_barCount, " @ ", TimeToString(TimeCurrent()), " ===");
   Print("HTF LOWS: ", ArraySize(g_htfFractalLows));
   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      int ltfBar = HTFTimeToLTFBar(g_htfFractalLows[i].time);
      Print("  L[", i, "] ", g_htfFractalLows[i].price,
            " @ ", TimeToString(g_htfFractalLows[i].time),
            " htf=", g_htfFractalLows[i].barIndex, " ltf=", ltfBar);
   }
   Print("HTF HIGHS: ", ArraySize(g_htfFractalHighs));
   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      int ltfBar = HTFTimeToLTFBar(g_htfFractalHighs[i].time);
      Print("  H[", i, "] ", g_htfFractalHighs[i].price,
            " @ ", TimeToString(g_htfFractalHighs[i].time),
            " htf=", g_htfFractalHighs[i].barIndex, " ltf=", ltfBar);
   }
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
bool FindBuyRaid(RaidInfo &raid)
{
   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      double fp = g_htfFractalLows[i].price;
      datetime ft = g_htfFractalLows[i].time;
      if(IsBuyRaidFullyUsed(ft)) continue;

      int fBar = HTFTimeToLTFBar(ft);
      if(fBar < 0 || fBar <= 1) continue;

      for(int j = fBar - 1; j >= 1; j--)
      {
         if(iLow(Symbol(), LTF_Period, j) < fp)
         {
            raid.fractalPrice = fp;
            raid.fractalTime = ft;
            raid.raidBarLTF = j;
            raid.fractalLTFBar = fBar;

            if(EnableDebugLog)
               Print("  BUY RAID: frac=", fp, " @ ", TimeToString(ft),
                     " raid@bar", j, "(", TimeToString(iTime(Symbol(), LTF_Period, j)), ")");
            return true;
         }
      }
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
               Print("  SELL RAID: frac=", fp, " @ ", TimeToString(ft),
                     " raid@bar", j, "(", TimeToString(iTime(Symbol(), LTF_Period, j)), ")");
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if bar i is an LTF swing low (fractal low on M1)           |
//+------------------------------------------------------------------+
bool IsLTFSwingLow(int i)
{
   if(i < LTF_SwingBars || i >= LTF_LookbackBars - LTF_SwingBars) return false;
   double low_i = iLow(Symbol(), LTF_Period, i);
   for(int j = 1; j <= LTF_SwingBars; j++)
   {
      if(iLow(Symbol(), LTF_Period, i-j) <= low_i) return false;
      if(iLow(Symbol(), LTF_Period, i+j) <= low_i) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if bar i is an LTF swing high (fractal high on M1)         |
//+------------------------------------------------------------------+
bool IsLTFSwingHigh(int i)
{
   if(i < LTF_SwingBars || i >= LTF_LookbackBars - LTF_SwingBars) return false;
   double high_i = iHigh(Symbol(), LTF_Period, i);
   for(int j = 1; j <= LTF_SwingBars; j++)
   {
      if(iHigh(Symbol(), LTF_Period, i-j) >= high_i) return false;
      if(iHigh(Symbol(), LTF_Period, i+j) >= high_i) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Find bullish breaker (for BUY)                                    |
//| Strategy: "the most recent highest price point that took out a    |
//| fractal low" on the LTF                                           |
//|                                                                    |
//| 1. Scan M1 for fractal lows (most recent first)                   |
//| 2. Check if each was taken out (price went below it after)        |
//| 3. For the most recent taken-out fractal low:                     |
//|    find the highest high BEFORE it = the breaker                  |
//| 4. SL = lowest price from breaker to recovery above breaker       |
//+------------------------------------------------------------------+
bool FindBullishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;
   int searchStart = 1 + LTF_SwingBars;
   // Search range: from most recent bars up to well beyond the raid
   int searchEnd = MathMin(raidBar + 100, LTF_LookbackBars - LTF_SwingBars - 1);

   for(int i = searchStart; i <= searchEnd; i++)
   {
      // Check if bar i is an M1 fractal low (swing low)
      if(!IsLTFSwingLow(i)) continue;

      double swingLowPrice = iLow(Symbol(), LTF_Period, i);

      // Was this fractal low taken out?
      // Check if any bar AFTER it (closer to present) has low < swingLowPrice
      bool takenOut = false;
      for(int k = i - 1; k >= 1; k--)
      {
         if(iLow(Symbol(), LTF_Period, k) < swingLowPrice)
         { takenOut = true; break; }
      }
      if(!takenOut) continue;

      // This M1 fractal low was taken out.
      // Find the highest high BEFORE this fractal low
      // = the peak from which price dropped to take out the fractal
      double highestPrice = 0;
      int highestBar = -1;

      for(int k = i; k <= MathMin(i + 50, LTF_LookbackBars - 1); k++)
      {
         double hi = iHigh(Symbol(), LTF_Period, k);
         if(hi > highestPrice)
         {
            highestPrice = hi;
            highestBar = k;
         }
         // Stop 10 bars after peak (found the local peak)
         if(highestBar >= 0 && (k - highestBar) >= 10)
            break;
      }

      if(highestBar < 0) continue;

      // SL = the lowest price the breaker caused
      // = lowest low from breaker peak down to recovery
      double lowestLow = DBL_MAX;
      for(int k = highestBar; k >= 1; k--)
      {
         double lo = iLow(Symbol(), LTF_Period, k);
         if(lo < lowestLow) lowestLow = lo;
         // Stop when price recovers above the breaker
         if(k < i && iClose(Symbol(), LTF_Period, k) > highestPrice)
            break;
      }

      brk.level = highestPrice;
      brk.slLevel = lowestLow;
      brk.breakerBar = highestBar;

      if(EnableDebugLog)
         Print("  BUY BRK: M1 swing low @bar", i,
               "(", TimeToString(iTime(Symbol(), LTF_Period, i)), ") p=", swingLowPrice,
               " taken out -> peak=", highestPrice,
               " @bar", highestBar, "(", TimeToString(iTime(Symbol(), LTF_Period, highestBar)), ")",
               " SL=", lowestLow);

      return true;
   }

   if(EnableDebugLog)
      Print("  BUY BRK: no taken-out M1 swing low found");

   return false;
}

//+------------------------------------------------------------------+
//| Find bearish breaker (for SELL)                                   |
//| Mirror of bullish: "most recent lowest price point that took out  |
//| a fractal high" on the LTF                                        |
//+------------------------------------------------------------------+
bool FindBearishBreaker(RaidInfo &raid, BreakerInfo &brk)
{
   int raidBar = raid.raidBarLTF;
   int searchStart = 1 + LTF_SwingBars;
   int searchEnd = MathMin(raidBar + 100, LTF_LookbackBars - LTF_SwingBars - 1);

   for(int i = searchStart; i <= searchEnd; i++)
   {
      if(!IsLTFSwingHigh(i)) continue;

      double swingHighPrice = iHigh(Symbol(), LTF_Period, i);

      // Was this fractal high taken out?
      bool takenOut = false;
      for(int k = i - 1; k >= 1; k--)
      {
         if(iHigh(Symbol(), LTF_Period, k) > swingHighPrice)
         { takenOut = true; break; }
      }
      if(!takenOut) continue;

      // Find the lowest low BEFORE this fractal high
      double lowestPrice = DBL_MAX;
      int lowestBar = -1;

      for(int k = i; k <= MathMin(i + 50, LTF_LookbackBars - 1); k++)
      {
         double lo = iLow(Symbol(), LTF_Period, k);
         if(lo < lowestPrice)
         {
            lowestPrice = lo;
            lowestBar = k;
         }
         if(lowestBar >= 0 && (k - lowestBar) >= 10)
            break;
      }

      if(lowestBar < 0) continue;

      // SL = highest high from breaker to recovery
      double highestHigh = 0;
      for(int k = lowestBar; k >= 1; k--)
      {
         double hi = iHigh(Symbol(), LTF_Period, k);
         if(hi > highestHigh) highestHigh = hi;
         if(k < i && iClose(Symbol(), LTF_Period, k) < lowestPrice)
            break;
      }

      brk.level = lowestPrice;
      brk.slLevel = highestHigh;
      brk.breakerBar = lowestBar;

      if(EnableDebugLog)
         Print("  SELL BRK: M1 swing high @bar", i,
               "(", TimeToString(iTime(Symbol(), LTF_Period, i)), ") p=", swingHighPrice,
               " taken out -> trough=", lowestPrice,
               " @bar", lowestBar, "(", TimeToString(iTime(Symbol(), LTF_Period, lowestBar)), ")",
               " SL=", highestHigh);

      return true;
   }

   if(EnableDebugLog)
      Print("  SELL BRK: no taken-out M1 swing high found");

   return false;
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

   // Option 2: first candle that closes above breaker
   if((EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS) && !opt2Done)
   {
      if(lastClose > brk.level && prevClose <= brk.level)
         opt2 = true;

      if(EnableDebugLog)
         Print("  OPT2: c1=", lastClose, " c2=", prevClose,
               " brk=", brk.level, " ->", opt2);
   }

   // Option 1: after a close above breaker, price retests it and bounces
   if((EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS) && !opt1Done)
   {
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) > brk.level)
         { hasBroken = true; break; }
      }

      double retestTol = 3.0 * Point * 10;
      if(hasBroken && lastLow <= brk.level + retestTol &&
         lastClose > brk.level && lastClose > lastOpen)
         opt1 = true;

      if(EnableDebugLog)
         Print("  OPT1: broken=", hasBroken, " lo=", lastLow,
               " cl=", lastClose, " op=", lastOpen,
               " brk=", brk.level, " ->", opt1);
   }

   if(!opt1 && !opt2) return;

   double sl = brk.slLevel - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl >= ask)
   {
      if(EnableDebugLog) Print("  SKIP: SL=", sl, " >= ask=", ask);
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
            " E=", ask, " SL=", sl, " TP=", tp, " Lots=", lots,
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
            " E=", bid, " SL=", sl, " TP=", tp, " Lots=", lots,
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
