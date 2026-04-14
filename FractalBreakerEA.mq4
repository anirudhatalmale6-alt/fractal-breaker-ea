//+------------------------------------------------------------------+
//|                                            FractalBreakerEA.mq4  |
//|                                    Fractal Liquidity + Breaker   |
//|                                    Block Entry Expert Advisor    |
//+------------------------------------------------------------------+
#property copyright "FractalBreakerEA"
#property version   "3.00"
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
input int        LTF_SwingBars    = 3;           // Swing detection bars each side (LTF)
input int        HTF_LookbackBars = 20;          // HTF bars to look back for fractals
input int        LTF_LookbackBars = 200;         // LTF bars to look back
input int        RaidPips         = 0;           // Min pips beyond fractal (0=any)

input string     _sep5_           = "=== Debug ===";
input bool       EnableDebugLog   = false;       // Print debug info to Journal

//--- Global variables
datetime g_lastBarTime = 0;
datetime g_lastBuyFractalUsed  = 0;
datetime g_lastSellFractalUsed = 0;

//--- Structures
struct FractalLevel {
   double price;
   datetime time;
   int barIndex;
   int htfSource;
   ENUM_TIMEFRAMES tf;
};

struct RaidInfo {
   double fractalPrice;
   datetime fractalTime;
   int raidBarLTF;
   int fractalLTFBar;
};

struct BreakerInfo {
   double level;       // breaker price (the high/low before the LTF fractal)
   double slLevel;     // SL price (the LTF fractal low/high itself)
   int breakerBar;     // LTF bar index of the breaker high/low
   int fractalBar;     // LTF bar index of the LTF fractal low/high
};

FractalLevel g_htfFractalLows[];
FractalLevel g_htfFractalHighs[];

//+------------------------------------------------------------------+
int OnInit()
{
   Print("FractalBreakerEA v3.00. HTF1=", EnumToString(HTF_Period_1),
         " HTF2=", (UseHTF2 ? EnumToString(HTF_Period_2) : "Off"),
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

   if(TradeDirection == BOTH_DIRS || TradeDirection == BUY_ONLY)
      CheckBuySetup();
   if(TradeDirection == BOTH_DIRS || TradeDirection == SELL_ONLY)
      CheckSellSetup();
}

//+------------------------------------------------------------------+
//| HTF Fractal Detection                                             |
//+------------------------------------------------------------------+
void DetectHTFFractals()
{
   ArrayResize(g_htfFractalLows, 0);
   ArrayResize(g_htfFractalHighs, 0);
   DetectFractalsOnTF(HTF_Period_1, FractalBars, 1);
   if(UseHTF2) DetectFractalsOnTF(HTF_Period_2, FractalBars, 2);

   if(EnableDebugLog)
   {
      static int logCount = 0;
      logCount++;
      if(logCount % 60 == 1)
      {
         Print("HTF: ", ArraySize(g_htfFractalLows), " lows, ",
               ArraySize(g_htfFractalHighs), " highs");
         for(int i = 0; i < MathMin(ArraySize(g_htfFractalLows), 5); i++)
            Print("  Low[", i, "] ", g_htfFractalLows[i].price,
                  " @ ", TimeToString(g_htfFractalLows[i].time));
      }
   }
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
//| LTF Swing Detection helpers                                       |
//+------------------------------------------------------------------+
bool IsSwingHigh(int bar)
{
   int n = LTF_SwingBars;
   if(bar - n < 0 || bar + n >= LTF_LookbackBars) return false;
   double h = iHigh(Symbol(), LTF_Period, bar);
   for(int j = 1; j <= n; j++)
   {
      if(iHigh(Symbol(), LTF_Period, bar-j) >= h ||
         iHigh(Symbol(), LTF_Period, bar+j) >= h)
         return false;
   }
   return true;
}

bool IsSwingLow(int bar)
{
   int n = LTF_SwingBars;
   if(bar - n < 0 || bar + n >= LTF_LookbackBars) return false;
   double l = iLow(Symbol(), LTF_Period, bar);
   for(int j = 1; j <= n; j++)
   {
      if(iLow(Symbol(), LTF_Period, bar-j) <= l ||
         iLow(Symbol(), LTF_Period, bar+j) <= l)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Find HTF fractal LOW raid                                         |
//+------------------------------------------------------------------+
bool FindBuyRaid(RaidInfo &raid)
{
   double threshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_htfFractalLows); i++)
   {
      double fp = g_htfFractalLows[i].price;
      datetime ft = g_htfFractalLows[i].time;
      if(ft == g_lastBuyFractalUsed) continue;

      int fBar = HTFTimeToLTFBar(ft);
      if(fBar < 0) continue;

      // Find raid: first LTF bar after fractal that goes below it
      for(int j = fBar - 1; j >= 1; j--)
      {
         if(iLow(Symbol(), LTF_Period, j) < fp - threshold)
         {
            raid.fractalPrice = fp;
            raid.fractalTime = ft;
            raid.raidBarLTF = j;
            raid.fractalLTFBar = fBar;

            if(EnableDebugLog)
               Print("BUY RAID: Frac=", fp, " FracBar=", fBar,
                     " RaidBar=", j, " @ ", TimeToString(iTime(Symbol(), LTF_Period, j)));
            return true;
         }
      }
   }
   if(EnableDebugLog)
   {
      static int noRaidLog = 0;
      noRaidLog++;
      if(noRaidLog % 60 == 1)
         Print("BUY: No raid found");
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find HTF fractal HIGH raid                                        |
//+------------------------------------------------------------------+
bool FindSellRaid(RaidInfo &raid)
{
   double threshold = RaidPips * Point * 10;

   for(int i = 0; i < ArraySize(g_htfFractalHighs); i++)
   {
      double fp = g_htfFractalHighs[i].price;
      datetime ft = g_htfFractalHighs[i].time;
      if(ft == g_lastSellFractalUsed) continue;

      int fBar = HTFTimeToLTFBar(ft);
      if(fBar < 0) continue;

      for(int j = fBar - 1; j >= 1; j--)
      {
         if(iHigh(Symbol(), LTF_Period, j) > fp + threshold)
         {
            raid.fractalPrice = fp;
            raid.fractalTime = ft;
            raid.raidBarLTF = j;
            raid.fractalLTFBar = fBar;

            if(EnableDebugLog)
               Print("SELL RAID: Frac=", fp, " FracBar=", fBar,
                     " RaidBar=", j, " @ ", TimeToString(iTime(Symbol(), LTF_Period, j)));
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find bullish breaker (for BUY)                                    |
//| = Most recent LTF fractal low, then the swing high before it     |
//| SL = the fractal low price                                        |
//+------------------------------------------------------------------+
bool FindBullishBreaker(BreakerInfo &brk)
{
   int n = LTF_SwingBars;

   // Step 1: Find the most recent LTF fractal low (swing low)
   int fracLowBar = -1;
   double fracLowPrice = 0;

   for(int i = n; i < LTF_LookbackBars - n; i++)
   {
      if(IsSwingLow(i))
      {
         fracLowBar = i;
         fracLowPrice = iLow(Symbol(), LTF_Period, i);
         break; // most recent one
      }
   }

   if(fracLowBar < 0)
   {
      if(EnableDebugLog) Print("BUY: No LTF swing low found");
      return false;
   }

   // Step 2: Find the swing high BEFORE this fractal low
   // This is the highest point right before the drop that took out the fractal low
   int swingHighBar = -1;
   double swingHighPrice = 0;

   for(int i = fracLowBar + 1; i < LTF_LookbackBars - n; i++)
   {
      if(IsSwingHigh(i))
      {
         swingHighBar = i;
         swingHighPrice = iHigh(Symbol(), LTF_Period, i);
         break; // first (most recent) swing high before the fractal low
      }
   }

   if(swingHighBar < 0)
   {
      if(EnableDebugLog) Print("BUY: No swing high before LTF fractal low");
      return false;
   }

   brk.level = swingHighPrice;
   brk.slLevel = fracLowPrice;
   brk.breakerBar = swingHighBar;
   brk.fractalBar = fracLowBar;

   if(EnableDebugLog)
      Print("BUY BREAKER: Level=", swingHighPrice,
            " @ bar ", swingHighBar, " (", TimeToString(iTime(Symbol(), LTF_Period, swingHighBar)), ")",
            " FracLow=", fracLowPrice,
            " @ bar ", fracLowBar, " (", TimeToString(iTime(Symbol(), LTF_Period, fracLowBar)), ")");

   return true;
}

//+------------------------------------------------------------------+
//| Find bearish breaker (for SELL)                                   |
//| = Most recent LTF fractal high, then the swing low before it     |
//| SL = the fractal high price                                       |
//+------------------------------------------------------------------+
bool FindBearishBreaker(BreakerInfo &brk)
{
   int n = LTF_SwingBars;

   // Step 1: Find the most recent LTF fractal high (swing high)
   int fracHighBar = -1;
   double fracHighPrice = 0;

   for(int i = n; i < LTF_LookbackBars - n; i++)
   {
      if(IsSwingHigh(i))
      {
         fracHighBar = i;
         fracHighPrice = iHigh(Symbol(), LTF_Period, i);
         break;
      }
   }

   if(fracHighBar < 0) return false;

   // Step 2: Find the swing low BEFORE this fractal high
   int swingLowBar = -1;
   double swingLowPrice = 0;

   for(int i = fracHighBar + 1; i < LTF_LookbackBars - n; i++)
   {
      if(IsSwingLow(i))
      {
         swingLowBar = i;
         swingLowPrice = iLow(Symbol(), LTF_Period, i);
         break;
      }
   }

   if(swingLowBar < 0) return false;

   brk.level = swingLowPrice;
   brk.slLevel = fracHighPrice;
   brk.breakerBar = swingLowBar;
   brk.fractalBar = fracHighBar;

   if(EnableDebugLog)
      Print("SELL BREAKER: Level=", swingLowPrice,
            " @ bar ", swingLowBar, " (", TimeToString(iTime(Symbol(), LTF_Period, swingLowBar)), ")",
            " FracHigh=", fracHighPrice,
            " @ bar ", fracHighBar, " (", TimeToString(iTime(Symbol(), LTF_Period, fracHighBar)), ")");

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

   // Step 2: Find bullish breaker on LTF
   BreakerInfo brk;
   if(!FindBullishBreaker(brk)) return;

   // Step 3: Check entry on last closed candle (bar 1)
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastLow   = iLow(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);
   double prevClose = iClose(Symbol(), LTF_Period, 2);

   bool opt1 = false;
   bool opt2 = false;

   // Option 2: Candle closes above breaker = immediate entry
   // Previous candle was below, this one closes above
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastClose > brk.level && prevClose <= brk.level)
         opt2 = true;

      if(EnableDebugLog)
         Print("BUY OPT2: lastClose=", lastClose, " prevClose=", prevClose,
               " brk=", brk.level, " signal=", opt2);
   }

   // Option 1: A candle must have already closed above breaker,
   // then price retests (dips back to) the breaker and bounces
   if(EntryMode == OPTION_1 || EntryMode == BOTH_OPTIONS)
   {
      // Check if any candle between breaker and now already closed above
      bool hasBroken = false;
      for(int k = 2; k < brk.breakerBar; k++)
      {
         if(iClose(Symbol(), LTF_Period, k) > brk.level)
         { hasBroken = true; break; }
      }

      if(hasBroken)
      {
         // Retest: candle dips to breaker level but closes above it
         if(lastLow <= brk.level && lastClose > brk.level && lastClose > lastOpen)
            opt1 = true;
      }

      if(EnableDebugLog)
         Print("BUY OPT1: hasBroken=", hasBroken, " lastLow=", lastLow,
               " brk=", brk.level, " signal=", opt1);
   }

   if(!opt1 && !opt2) return;

   // SL = the fractal low (lowest point the breaker caused)
   double sl = brk.slLevel - MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl >= ask) return;

   double slDist = ask - sl;
   double tp = ask + (slDist * RR_Ratio) + MarketInfo(Symbol(), MODE_SPREAD) * Point;

   double lots = CalcLots(slDist);
   if(lots <= 0) return;

   if(HasTradeAtLevel(brk.level, OP_BUY)) return;

   string comment = "FBE_BUY_OPT" + IntegerToString(opt1 ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_BUY, lots, ask, 3, sl, tp, comment, MagicNumber, 0, clrGreen);

   if(ticket > 0)
   {
      g_lastBuyFractalUsed = raid.fractalTime;
      Print("BUY #", ticket, " E=", ask, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (opt1?"1":"2"),
            " Brk=", brk.level, " Frac=", raid.fractalPrice);
   }
   else Print("BUY FAIL: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Check SELL setup                                                 |
//+------------------------------------------------------------------+
void CheckSellSetup()
{
   RaidInfo raid;
   if(!FindSellRaid(raid)) return;

   BreakerInfo brk;
   if(!FindBearishBreaker(brk)) return;

   double bid = MarketInfo(Symbol(), MODE_BID);
   double lastClose = iClose(Symbol(), LTF_Period, 1);
   double lastHigh  = iHigh(Symbol(), LTF_Period, 1);
   double lastOpen  = iOpen(Symbol(), LTF_Period, 1);
   double prevClose = iClose(Symbol(), LTF_Period, 2);

   bool opt1 = false;
   bool opt2 = false;

   // Option 2: Candle closes below breaker
   if(EntryMode == OPTION_2 || EntryMode == BOTH_OPTIONS)
   {
      if(lastClose < brk.level && prevClose >= brk.level)
         opt2 = true;
   }

   // Option 1: After break below, retest from below
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

   if(!opt1 && !opt2) return;

   double sl = brk.slLevel + MarketInfo(Symbol(), MODE_SPREAD) * Point;
   if(sl <= bid) return;

   double slDist = sl - bid;
   double tp = bid - (slDist * RR_Ratio) - MarketInfo(Symbol(), MODE_SPREAD) * Point;

   double lots = CalcLots(slDist);
   if(lots <= 0) return;

   if(HasTradeAtLevel(brk.level, OP_SELL)) return;

   string comment = "FBE_SELL_OPT" + IntegerToString(opt1 ? 1 : 2);
   int ticket = OrderSend(Symbol(), OP_SELL, lots, bid, 3, sl, tp, comment, MagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      g_lastSellFractalUsed = raid.fractalTime;
      Print("SELL #", ticket, " E=", bid, " SL=", sl, " TP=", tp,
            " L=", lots, " Opt=", (opt1?"1":"2"),
            " Brk=", brk.level, " Frac=", raid.fractalPrice);
   }
   else Print("SELL FAIL: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Lot size calculation                                              |
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

//+------------------------------------------------------------------+
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

bool HasTradeAtLevel(double level, int type)
{
   double tol = 10 * Point;
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != type) continue;
      if(MathAbs(OrderOpenPrice() - level) < tol) return true;
   }
   return false;
}
//+------------------------------------------------------------------+
