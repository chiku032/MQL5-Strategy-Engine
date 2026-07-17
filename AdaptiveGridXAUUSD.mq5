//+------------------------------------------------------------------+
//|                                       AdaptiveGridXAUUSD.mq5      |
//|   Adaptive AI-style Grid / Hedge Engine for XAUUSD (Cent account)|
//|                                                                    |
//|   Modules (each implemented as a class below):                   |
//|     CMarketClassifier  - Range/Trend/Transition scoring engine   |
//|     CVolatilityEngine  - ATR expansion/compression tracking      |
//|     CSessionEngine     - Asian/London/NY session detection       |
//|     CStatisticsEngine  - rolling market memory (mode durations)  |
//|     CGridEngine        - dynamic grid gap calculation            |
//|     CMoneyManager      - adaptive (non-martingale) lot sizing    |
//|     CBasketManager     - opens/manages/closes BUY & SELL baskets |
//|     CHedgeEngine       - partial mathematical hedge module       |
//|     CRiskManager       - dd limits, emergency stop, filters      |
//|     CDashboard         - on-chart live status panel              |
//|                                                                    |
//|   IMPORTANT: this is a first-pass build. Compile in MetaEditor,  |
//|   fix any environment-specific warnings, and validate in the     |
//|   Strategy Tester on a demo/cent account before live use.        |
//+------------------------------------------------------------------+
#property copyright "Adaptive Grid Engine"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//====================================================================
// INPUT PARAMETERS
//====================================================================
input group "=== General ==="
input double   InpBaseLot                 = 0.01;     // Base Lot
input double   InpMaxLot                  = 0.50;     // Maximum Lot per single order
input int      InpMaxTradesRange          = 25;       // Max trades - Strong Range
input int      InpMaxTradesWeakRange      = 10;       // Max trades - Weak Range
input int      InpMaxTradesTrendDefensive = 5;         // Max trades on the defensive side in a trend
input ulong    InpMagicBuy                = 770001;   // Magic - Buy basket
input ulong    InpMagicSell               = 770002;   // Magic - Sell basket
input ulong    InpMagicHedgeBuy           = 770011;   // Magic - Hedge (long)
input ulong    InpMagicHedgeSell          = 770012;   // Magic - Hedge (short)

input group "=== Indicators ==="
input int      InpATRPeriod               = 14;
input int      InpADXPeriod               = 14;
input int      InpEMAPeriod               = 50;
input int      InpBBPeriod                = 20;
input double   InpBBDeviation             = 2.0;
input int      InpDonchianPeriod          = 20;

input group "=== Classification ==="
input int      InpConfirmBars             = 7;        // Mode confirmation bars (5-10)
input double   InpADXTrendLevel           = 25.0;     // ADX above this => trend leaning
input double   InpADXRangeLevel           = 18.0;     // ADX below this => range leaning

input group "=== Grid Multipliers ==="
input double   InpRangeGapMult            = 0.35;     // Strong range: ATR x mult
input double   InpWeakRangeGapMult        = 0.60;     // Weak range: ATR x mult
input double   InpTrendDefGapMult         = 2.50;     // Defensive side in trend: ATR x mult
input double   InpTrendAggGapMult         = 0.55;     // With-trend side: ATR x mult

input group "=== Basket Profit Targets (account currency) ==="
input double   InpBasketProfitRange       = 10.0;     // Strong range basket TP
input double   InpBasketProfitWeakRange   = 14.0;     // Weak range basket TP
input double   InpBasketProfitTrend       = 8.0;      // Trend-mode basket TP (per side)
input double   InpTrailStartProfit        = 6.0;      // Start trailing basket profit above this
input double   InpTrailStep               = 1.5;      // Give-back allowed once trailing

input group "=== Smart Hedge Engine ==="
input double   InpHedgeTriggerPct         = 3.0;      // Basket floating loss % of balance to trigger hedge
input double   InpMaxHedgePct             = 70.0;     // Max hedge volume as % of basket volume
input double   InpHedgeStepPct            = 30.0;     // Hedge scales in / out in steps of this %

input group "=== Risk Engine ==="
input double   InpMaxDailyDrawdownPct     = 8.0;      // Max daily drawdown %
input double   InpMaxFloatingDrawdownPct  = 15.0;     // Max floating (open) drawdown %
input double   InpMaxTotalLots            = 5.0;      // Max total lots open across all baskets
input double   InpMaxMarginUsagePct       = 60.0;     // Max margin usage %
input double   InpMaxSpreadPoints         = 350;       // Max allowed spread (points) to open new trades
input bool     InpDailyProfitLock         = true;     // Stop opening new baskets after daily target hit
input double   InpDailyProfitTargetPct    = 5.0;      // Daily profit target %

input group "=== Safety ==="
input double   InpAbnormalATRMult         = 3.0;      // ATR spike multiplier considered abnormal
input double   InpAbnormalSpreadMult      = 3.0;      // Spread spike multiplier considered abnormal

input group "=== Misc ==="
input int      InpSlippage                = 30;
input bool     InpShowDashboard           = true;
input string   InpTradeComment            = "AdaptiveGrid";

//====================================================================
// GLOBALS
//====================================================================
CTrade         trade;
CPositionInfo  posInfo;

int hATR, hADX, hEMA, hBB;
datetime lastBarTime = 0;

double g_dayStartEquity = 0.0;
datetime g_dayStamp = 0;

enum MARKET_MODE
{
   MODE_RANGE_STRONG = 0,
   MODE_RANGE_WEAK   = 1,
   MODE_TREND_UP     = 2,
   MODE_TREND_DOWN   = 3,
   MODE_TRANSITION   = 4
};

string ModeToString(MARKET_MODE m)
{
   switch(m)
   {
      case MODE_RANGE_STRONG: return "STRONG RANGE";
      case MODE_RANGE_WEAK:   return "WEAK RANGE";
      case MODE_TREND_UP:     return "TREND UP";
      case MODE_TREND_DOWN:   return "TREND DOWN";
      default:                return "TRANSITION";
   }
}

//====================================================================
// CLASS: CVolatilityEngine
//====================================================================
class CVolatilityEngine
{
public:
   double currentATR;
   double avgATR;      // rolling average ATR (compression/expansion baseline)
   double volFactor;    // >1 = expanded, <1 = compressed

   void Update(const double &atrBuf[], int count)
   {
      if(count < 2) return;
      currentATR = atrBuf[0];
      double sum = 0;
      int n = MathMin(count, 100);
      for(int i=0;i<n;i++) sum += atrBuf[i];
      avgATR = sum / n;
      volFactor = (avgATR > 0) ? currentATR/avgATR : 1.0;
   }

   bool IsAbnormal(double mult) const
   {
      return (avgATR>0 && currentATR > avgATR*mult);
   }
};

//====================================================================
// CLASS: CSessionEngine
//====================================================================
class CSessionEngine
{
public:
   enum SESSION { SESSION_ASIAN, SESSION_LONDON, SESSION_NEWYORK, SESSION_OFF };

   SESSION Current()
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int h = dt.hour; // server time hour
      if(h>=0 && h<8)   return SESSION_ASIAN;
      if(h>=8 && h<13)  return SESSION_LONDON;
      if(h>=13 && h<21) return SESSION_NEWYORK;
      return SESSION_OFF;
   }

   string Name()
   {
      switch(Current())
      {
         case SESSION_ASIAN:   return "Asian";
         case SESSION_LONDON:  return "London";
         case SESSION_NEWYORK: return "New York";
         default:               return "Off/Overlap-Low";
      }
   }

   // Session density multiplier applied to grid gap (Asian denser -> smaller gap)
   double GapMultiplier()
   {
      switch(Current())
      {
         case SESSION_ASIAN:   return 0.85;
         case SESSION_LONDON:  return 1.00;
         case SESSION_NEWYORK: return 1.10;
         default:               return 1.25;
      }
   }
};

//====================================================================
// CLASS: CStatisticsEngine (Market Memory)
//====================================================================
class CStatisticsEngine
{
private:
   int    modeBarCounter;
   MARKET_MODE lastMode;
   double rangeLengths[];   // bars spent in range modes, rolling
   double trendLengths[];   // bars spent in trend modes, rolling
   int    maxSamples;

   void PushSample(double &arr[], double val)
   {
      int n = ArraySize(arr);
      if(n < maxSamples)
      {
         ArrayResize(arr, n+1);
         arr[n] = val;
      }
      else
      {
         for(int i=1;i<n;i++) arr[i-1]=arr[i];
         arr[n-1]=val;
      }
   }

   double Average(const double &arr[])
   {
      int n = ArraySize(arr);
      if(n==0) return 0;
      double s=0; for(int i=0;i<n;i++) s+=arr[i];
      return s/n;
   }

public:
   void Init()
   {
      modeBarCounter = 0;
      lastMode = MODE_TRANSITION;
      maxSamples = 60; // ~ last 60 completed swings kept (bounded memory)
      ArrayResize(rangeLengths,0);
      ArrayResize(trendLengths,0);
   }

   // call once per new bar with the (already hysteresis-confirmed) mode
   void OnNewBar(MARKET_MODE confirmedMode)
   {
      bool wasRange = (lastMode==MODE_RANGE_STRONG || lastMode==MODE_RANGE_WEAK);
      bool wasTrend = (lastMode==MODE_TREND_UP || lastMode==MODE_TREND_DOWN);
      bool isRange  = (confirmedMode==MODE_RANGE_STRONG || confirmedMode==MODE_RANGE_WEAK);
      bool isTrend  = (confirmedMode==MODE_TREND_UP || confirmedMode==MODE_TREND_DOWN);

      if(confirmedMode==lastMode || (wasRange&&isRange) || (wasTrend&&isTrend))
      {
         modeBarCounter++;
      }
      else
      {
         // mode family changed -> log completed run length
         if(wasRange) PushSample(rangeLengths, modeBarCounter);
         if(wasTrend) PushSample(trendLengths, modeBarCounter);
         modeBarCounter = 1;
      }
      lastMode = confirmedMode;
   }

   double AvgRangeLengthBars() { return Average(rangeLengths); }
   double AvgTrendLengthBars() { return Average(trendLengths); }

   // Feedback multiplier: if ranges have historically been short-lived,
   // trade a bit smaller/tighter TP so baskets can close before mode flips.
   double RangeDurationFeedback()
   {
      double avg = AvgRangeLengthBars();
      if(avg<=0) return 1.0;
      if(avg < InpConfirmBars*2) return 0.85; // ranges are typically short -> tighten
      if(avg > InpConfirmBars*6) return 1.15; // ranges typically long -> can extend
      return 1.0;
   }
};

//====================================================================
// CLASS: CMarketClassifier
//====================================================================
class CMarketClassifier
{
private:
   MARKET_MODE confirmedMode;
   MARKET_MODE candidateMode;
   int         candidateStreak;

   double NormLow(double v,double lo,double hi) // 1 when v<=lo, 0 when v>=hi
   {
      if(hi<=lo) return 0;
      double x = (hi - v)/(hi-lo);
      return MathMax(0.0, MathMin(1.0,x));
   }
   double NormHigh(double v,double lo,double hi) // 0 when v<=lo, 1 when v>=hi
   {
      if(hi<=lo) return 0;
      double x = (v - lo)/(hi-lo);
      return MathMax(0.0, MathMin(1.0,x));
   }

public:
   double rangeScore;
   double trendScore;
   int    trendDirection; // +1 up, -1 down, 0 none

   void Init()
   {
      confirmedMode   = MODE_TRANSITION;
      candidateMode   = MODE_TRANSITION;
      candidateStreak = 0;
      trendDirection  = 0;
   }

   MARKET_MODE Confirmed() const { return confirmedMode; }

   // Core scoring — call once per new bar
   MARKET_MODE Evaluate(const double &adx[], const double &plusDI[], const double &minusDI[],
                         const double &atr[], const double &bbUpper[], const double &bbLower[],
                         const double &ema[], const double &close[], const double &high[], const double &low[],
                         const double &open[], int bars)
   {
      int n = MathMin(bars, 60);
      if(n < 25) { rangeScore=0; trendScore=0; return confirmedMode; }

      //--- ADX component
      double adxNow = adx[0];
      double rADX = NormLow(adxNow, InpADXRangeLevel, InpADXTrendLevel);
      double tADX = NormHigh(adxNow, InpADXRangeLevel, InpADXTrendLevel);

      //--- ATR (current vs recent average) -> low ATR = range-ish, expanding ATR = trend-ish
      double atrAvg=0; for(int i=0;i<20 && i<n;i++) atrAvg+=atr[i]; atrAvg/=MathMin(20,n);
      double atrRatio = (atrAvg>0)? atr[0]/atrAvg : 1.0;
      double rATR = NormLow(atrRatio, 0.7, 1.3);
      double tATR = NormHigh(atrRatio, 0.9, 1.6);

      //--- Bollinger Band width (normalized by price)
      double bbWidthNow  = (bbUpper[0]-bbLower[0]);
      double bbWidthAvg=0; for(int i=0;i<20 && i<n;i++) bbWidthAvg += (bbUpper[i]-bbLower[i]);
      bbWidthAvg/=MathMin(20,n);
      double bbRatio = (bbWidthAvg>0)? bbWidthNow/bbWidthAvg : 1.0;
      double rBB = NormLow(bbRatio, 0.75, 1.25);
      double tBB = NormHigh(bbRatio, 0.9, 1.6);

      //--- EMA slope (flat = range, steep = trend) normalized in ATR units
      double emaSlope = (ema[0]-ema[MathMin(10,n-1)]);
      double emaSlopeATR = (atr[0]>0)? MathAbs(emaSlope)/atr[0] : 0;
      double rEMA = NormLow(emaSlopeATR, 0.3, 1.5);
      double tEMA = NormHigh(emaSlopeATR, 0.5, 2.5);

      //--- Linear regression slope over N closes (sign + magnitude in ATR units)
      int lrN = MathMin(14,n);
      double sumX=0,sumY=0,sumXY=0,sumXX=0;
      for(int i=0;i<lrN;i++)
      {
         double x = i;
         double y = close[lrN-1-i];
         sumX+=x; sumY+=y; sumXY+=x*y; sumXX+=x*x;
      }
      double denom = (lrN*sumXX - sumX*sumX);
      double lrSlope = (denom!=0)? (lrN*sumXY - sumX*sumY)/denom : 0;
      double lrSlopeATR = (atr[0]>0)? MathAbs(lrSlope)*lrN/atr[0] : 0;
      double rLR = NormLow(lrSlopeATR, 0.3, 1.5);
      double tLR = NormHigh(lrSlopeATR, 0.5, 2.5);

      //--- Price oscillation: direction changes over last 10 closes
      int dirChanges=0;
      for(int i=1;i<10 && i<n-1;i++)
      {
         double d1 = close[i-1]-close[i];
         double d2 = close[i]-close[i+1];
         if((d1>0 && d2<0)||(d1<0 && d2>0)) dirChanges++;
      }
      double rOsc = NormHigh(dirChanges, 2, 6);
      double tOsc = NormLow(dirChanges, 2, 6);

      //--- Donchian width (normalized by ATR)
      double hh=high[0], ll=low[0];
      int dcN = MathMin(InpDonchianPeriod,n);
      for(int i=0;i<dcN;i++){ if(high[i]>hh) hh=high[i]; if(low[i]<ll) ll=low[i]; }
      double dcWidthATR = (atr[0]>0)? (hh-ll)/atr[0] : 0;
      double rDC = NormLow(dcWidthATR, 2.0, 6.0);
      double tDC = NormHigh(dcWidthATR, 3.0, 8.0);

      //--- Inside bar frequency over last 10 bars (range signal)
      int insideCount=0;
      for(int i=0;i<10 && i<n-1;i++)
         if(high[i]<=high[i+1] && low[i]>=low[i+1]) insideCount++;
      double rInside = NormHigh(insideCount, 1, 4);

      //--- Candle body ratio / directional candle count (trend signal)
      int dirCandles=0;
      for(int i=0;i<10 && i<n;i++)
      {
         double body = MathAbs(close[i]-open[i]);
         double range = MathMax(high[i]-low[i], _Point);
         if(body/range > 0.6) dirCandles++;
      }
      double tBody = NormHigh(dirCandles, 2, 6);

      //--- Price hugging one Bollinger band (trend signal)
      int huggingCount=0;
      for(int i=0;i<10 && i<n;i++)
      {
         double bw = MathMax(bbUpper[i]-bbLower[i], _Point);
         if(close[i] > bbUpper[i]-bw*0.15 || close[i] < bbLower[i]+bw*0.15) huggingCount++;
      }
      double tHug = NormHigh(huggingCount, 2, 6);

      //--- Weighted sums (weights sum ~1.0 each side, tune as desired)
      rangeScore = 100.0*( rADX*0.20 + rATR*0.13 + rBB*0.15 + rEMA*0.13 + rLR*0.10 +
                           rOsc*0.12 + rDC*0.09 + rInside*0.08 );
      trendScore = 100.0*( tADX*0.20 + tATR*0.10 + tBB*0.12 + tEMA*0.14 + tLR*0.12 +
                           tOsc*0.08 + tDC*0.08 + tBody*0.08 + tHug*0.08 );

      //--- Direction (only meaningful if trend leaning)
      trendDirection = 0;
      if(plusDI[0] > minusDI[0]) trendDirection = 1;
      else if(minusDI[0] > plusDI[0]) trendDirection = -1;
      if(emaSlope < 0 && trendDirection==0) trendDirection = -1;
      if(emaSlope > 0 && trendDirection==0) trendDirection = 1;

      //--- Raw mode suggestion for this single bar
      MARKET_MODE rawMode;
      if(trendScore > rangeScore + 8.0) // meaningful edge required
      {
         rawMode = (trendDirection>=0) ? MODE_TREND_UP : MODE_TREND_DOWN;
      }
      else if(rangeScore > trendScore + 8.0)
      {
         rawMode = (rangeScore >= 62.0) ? MODE_RANGE_STRONG : MODE_RANGE_WEAK;
      }
      else
      {
         rawMode = MODE_TRANSITION;
      }

      //--- Hysteresis: require InpConfirmBars consecutive bars of the same
      //    raw suggestion before switching the confirmed mode.
      if(rawMode == candidateMode)
         candidateStreak++;
      else
      {
         candidateMode   = rawMode;
         candidateStreak = 1;
      }

      if(candidateStreak >= InpConfirmBars && candidateMode != confirmedMode)
         confirmedMode = candidateMode;

      return confirmedMode;
   }
};

//====================================================================
// CLASS: CGridEngine
//====================================================================
class CGridEngine
{
public:
   // Computes the current grid gap (in price) for a given basket side.
   // isDefensiveSide = true when this is the counter-trend side in a trending mode.
   double ComputeGap(MARKET_MODE mode, bool isDefensiveSide, double atr,
                      double volFactor, double sessionMult, double floatingDDPct)
   {
      double baseMult;
      switch(mode)
      {
         case MODE_RANGE_STRONG: baseMult = InpRangeGapMult; break;
         case MODE_RANGE_WEAK:   baseMult = InpWeakRangeGapMult; break;
         case MODE_TREND_UP:
         case MODE_TREND_DOWN:   baseMult = isDefensiveSide ? InpTrendDefGapMult : InpTrendAggGapMult; break;
         default:                 baseMult = InpWeakRangeGapMult; break;
      }

      // Drawdown multiplier: as floating DD grows, widen spacing & slow entries
      double ddMult = 1.0 + MathMax(0.0, floatingDDPct/InpMaxFloatingDrawdownPct) * 1.5;

      double gap = atr * baseMult * MathMax(0.6, MathMin(2.0, volFactor)) * sessionMult * ddMult;
      return MathMax(gap, _Point*10);
   }

   int MaxTradesForMode(MARKET_MODE mode, bool isDefensiveSide)
   {
      switch(mode)
      {
         case MODE_RANGE_STRONG: return InpMaxTradesRange;
         case MODE_RANGE_WEAK:   return InpMaxTradesWeakRange;
         case MODE_TREND_UP:
         case MODE_TREND_DOWN:   return isDefensiveSide ? InpMaxTradesTrendDefensive : InpMaxTradesRange/2;
         default:                 return 0; // no new baskets in transition
      }
   }
};

//====================================================================
// CLASS: CMoneyManager  (adaptive, non-martingale lot progression)
//====================================================================
class CMoneyManager
{
public:
   // Pattern: 1,1,2,2,3,3,5,5,... (Fibonacci-like, capped) x BaseLot
   double LotForStep(int stepIndex) // 0-based
   {
      static int pattern[] = {1,1,2,2,3,3,5,5,8,8,13,13};
      int idx = MathMin(stepIndex, ArraySize(pattern)-1);
      double lot = InpBaseLot * pattern[idx];
      lot = MathMin(lot, InpMaxLot);
      lot = NormalizeLot(lot);
      return lot;
   }

   double NormalizeLot(double lot)
   {
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step<=0) step = 0.01;
      double norm = MathRound(lot/step)*step;
      norm = MathMax(minLot, MathMin(maxLot, norm));
      return norm;
   }
};

//====================================================================
// CLASS: CBasketManager
//====================================================================
class CBasketManager
{
private:
   CGridEngine    *grid;
   CMoneyManager  *mm;

   double basketPeakProfit[2]; // 0=buy,1=sell — used for trailing basket profit

public:
   void Init(CGridEngine *g, CMoneyManager *m)
   {
      grid = g; mm = m;
      basketPeakProfit[0]=0; basketPeakProfit[1]=0;
   }

   int CountPositions(ulong magic)
   {
      int cnt=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         if(posInfo.Magic()==magic) cnt++;
      }
      return cnt;
   }

   double SumVolume(ulong magic)
   {
      double v=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         if(posInfo.Magic()==magic) v+=posInfo.Volume();
      }
      return v;
   }

   double SumProfit(ulong magic) // includes swap+commission
   {
      double p=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         if(posInfo.Magic()==magic)
            p += posInfo.Profit()+posInfo.Swap()+posInfo.Commission();
      }
      return p;
   }

   double LastEntryPrice(ulong magic, bool wantHighest) // highest for buy avg-up ref, etc.
   {
      double result = wantHighest ? -DBL_MAX : DBL_MAX;
      bool found=false;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         if(posInfo.Magic()!=magic) continue;
         found=true;
         double p = posInfo.PriceOpen();
         if(wantHighest && p>result) result=p;
         if(!wantHighest && p<result) result=p;
      }
      return found? result : 0.0;
   }

   double AvgEntryPrice(ulong magic)
   {
      double sumPV=0, sumV=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         if(posInfo.Magic()!=magic) continue;
         sumPV += posInfo.PriceOpen()*posInfo.Volume();
         sumV  += posInfo.Volume();
      }
      return (sumV>0)? sumPV/sumV : 0.0;
   }

   // Try to add a grid entry to a basket if price has moved 'gap' beyond the
   // last entry in the adverse direction (classic grid averaging logic).
   void TryGridEntry(bool isBuy, ulong magic, double gap, int maxTrades, string tag)
   {
      int cnt = CountPositions(magic);
      if(cnt<=0)
      {
         // basket empty: initial entry always allowed if global risk checks pass
         double lot = mm.LotForStep(0);
         OpenTrade(isBuy, magic, lot, tag);
         return;
      }
      if(cnt>=maxTrades) return;

      double ref = isBuy ? LastEntryPrice(magic,false) : LastEntryPrice(magic,true); // worst-case ref
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      bool trigger=false;
      if(isBuy  && bid <= ref - gap) trigger=true;
      if(!isBuy && ask >= ref + gap) trigger=true;

      if(trigger)
      {
         double lot = mm.LotForStep(cnt);
         OpenTrade(isBuy, magic, lot, tag);
      }
   }

   void OpenTrade(bool isBuy, ulong magic, double lot, string tag)
   {
      trade.SetExpertMagicNumber(magic);
      trade.SetDeviationInPoints(InpSlippage);
      lot = mm.NormalizeLot(lot);
      if(lot<=0) return;
      if(isBuy) trade.Buy(lot, _Symbol, 0,0,0, tag);
      else      trade.Sell(lot, _Symbol, 0,0,0, tag);
   }

   // Dynamic basket exit: TP adapts to volatility, and once in solid profit
   // we trail it rather than using a single fixed number.
   void ManageBasketExit(ulong magic, double baseTarget, double volFactor, int basketIdx)
   {
      int cnt = CountPositions(magic);
      if(cnt==0) { basketPeakProfit[basketIdx]=0; return; }

      double target = baseTarget * MathMax(0.7, MathMin(1.6, volFactor)); // wider TP when vol expands
      double profit = SumProfit(magic);

      if(profit > basketPeakProfit[basketIdx]) basketPeakProfit[basketIdx]=profit;

      bool closeNow=false;
      if(profit >= target) closeNow=true;

      // Trailing: once profit exceeded trail-start, allow a small giveback then lock
      if(basketPeakProfit[basketIdx] >= InpTrailStartProfit)
      {
         if(profit <= basketPeakProfit[basketIdx]-InpTrailStep && profit>0) closeNow=true;
      }

      if(closeNow)
      {
         CloseBasket(magic);
         basketPeakProfit[basketIdx]=0;
      }
   }

   void CloseBasket(ulong magic)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         if(posInfo.Magic()==magic)
         {
            trade.SetExpertMagicNumber(magic);
            trade.PositionClose(posInfo.Ticket(), InpSlippage);
         }
      }
   }

   void CloseFraction(ulong magic, double fraction) // partial scale-out (used by hedge engine)
   {
      fraction = MathMax(0.0, MathMin(1.0, fraction));
      if(fraction<=0) return;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         if(posInfo.Magic()!=magic) continue;
         double vol = posInfo.Volume();
         double closeVol = mm.NormalizeLot(vol*fraction);
         if(closeVol<=0) continue;
         trade.SetExpertMagicNumber(magic);
         trade.PositionClosePartial(posInfo.Ticket(), closeVol, InpSlippage);
      }
   }
};

//====================================================================
// CLASS: CHedgeEngine
//====================================================================
class CHedgeEngine
{
private:
   CBasketManager *bm;
   CMoneyManager  *mm;

public:
   void Init(CBasketManager *b, CMoneyManager *m) { bm=b; mm=m; }

   // basketMagic = the losing basket, hedgeMagic = its hedge counter-position magic
   // isBasketBuy = true if the losing basket is the BUY side
   void Manage(ulong basketMagic, ulong hedgeMagic, bool isBasketBuy,
               double trendScore, double atr, double equity, double balance)
   {
      double basketVol   = bm.SumVolume(basketMagic);
      if(basketVol<=0)
      {
         // basket empty -> unwind any leftover hedge fully
         if(bm.SumVolume(hedgeMagic)>0) bm.CloseBasket(hedgeMagic);
         return;
      }

      double basketProfit = bm.SumProfit(basketMagic);
      double lossPct = (balance>0)? (-basketProfit/balance*100.0) : 0.0;

      double hedgeVol = bm.SumVolume(hedgeMagic);

      if(lossPct >= InpHedgeTriggerPct)
      {
         // Desired hedge % scales with loss severity and trend strength against us,
         // but is capped at InpMaxHedgePct and always applied in InpHedgeStepPct steps.
         double severity   = MathMin(1.0, lossPct/(InpHedgeTriggerPct*3.0));
         double trendPush  = MathMin(1.0, trendScore/100.0);
         double desiredPct = MathMin(InpMaxHedgePct, (severity*0.6 + trendPush*0.4)*InpMaxHedgePct);

         // round to nearest step
         desiredPct = MathFloor(desiredPct/InpHedgeStepPct)*InpHedgeStepPct;
         double desiredVol = mm.NormalizeLot(basketVol*desiredPct/100.0);

         if(desiredVol > hedgeVol + 0.001)
         {
            double addVol = mm.NormalizeLot(desiredVol - hedgeVol);
            if(addVol>0)
            {
               trade.SetExpertMagicNumber(hedgeMagic);
               trade.SetDeviationInPoints(InpSlippage);
               // hedge is opposite direction of the losing basket
               if(isBasketBuy) trade.Sell(addVol, _Symbol, 0,0,0, "Hedge");
               else            trade.Buy(addVol, _Symbol, 0,0,0, "Hedge");
            }
         }
      }
      else
      {
         // Market recovering: scale hedge OUT gradually, never instantly.
         if(hedgeVol>0)
         {
            double reduceFraction = InpHedgeStepPct/100.0; // remove one step at a time
            bm.CloseFraction(hedgeMagic, reduceFraction);
         }
      }
   }
};

//====================================================================
// CLASS: CRiskManager
//====================================================================
class CRiskManager
{
public:
   bool emergencyStop;

   void Init() { emergencyStop=false; }

   double TotalLots()
   {
      double v=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         v+=posInfo.Volume();
      }
      return v;
   }

   double FloatingProfit()
   {
      double p=0;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Symbol()!=_Symbol) continue;
         p+=posInfo.Profit()+posInfo.Swap()+posInfo.Commission();
      }
      return p;
   }

   double FloatingDrawdownPct(double balance)
   {
      double p = FloatingProfit();
      if(p>=0 || balance<=0) return 0.0;
      return (-p/balance)*100.0;
   }

   double DailyDrawdownPct(double equity, double dayStartEquity)
   {
      if(dayStartEquity<=0) return 0.0;
      double dd = (dayStartEquity-equity)/dayStartEquity*100.0;
      return MathMax(0.0, dd);
   }

   double DailyProfitPct(double equity, double dayStartEquity)
   {
      if(dayStartEquity<=0) return 0.0;
      return (equity-dayStartEquity)/dayStartEquity*100.0;
   }

   bool SpreadOK()
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      return spread <= InpMaxSpreadPoints;
   }

   bool MarginOK()
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double marginUsed = AccountInfoDouble(ACCOUNT_MARGIN);
      if(equity<=0) return false;
      double pct = marginUsed/equity*100.0;
      return pct <= InpMaxMarginUsagePct;
   }

   bool CanOpenNewTrades(double equity, double balance, double dayStartEquity)
   {
      if(emergencyStop) return false;
      if(!SpreadOK()) return false;
      if(!MarginOK()) return false;
      if(TotalLots() >= InpMaxTotalLots) return false;
      if(FloatingDrawdownPct(balance) >= InpMaxFloatingDrawdownPct) return false;
      if(DailyDrawdownPct(equity, dayStartEquity) >= InpMaxDailyDrawdownPct) return false;
      if(InpDailyProfitLock && DailyProfitPct(equity, dayStartEquity) >= InpDailyProfitTargetPct) return false;
      return true;
   }

   void CheckEmergency(double equity, double balance, double dayStartEquity)
   {
      if(DailyDrawdownPct(equity, dayStartEquity) >= InpMaxDailyDrawdownPct*1.25 ||
         FloatingDrawdownPct(balance) >= InpMaxFloatingDrawdownPct*1.25)
      {
         emergencyStop = true;
      }
   }
};

//====================================================================
// CLASS: CDashboard
//====================================================================
class CDashboard
{
private:
   string prefix;
   void Label(string name, string text, int x, int y, color clr, int size=9)
   {
      string full = prefix+name;
      if(ObjectFind(0, full) < 0)
      {
         ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
         ObjectSetInteger(0, full, OBJPROP_FONTSIZE, size);
         ObjectSetString(0, full, OBJPROP_FONT, "Consolas");
      }
      ObjectSetString(0, full, OBJPROP_TEXT, text);
      ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
   }

public:
   void Init(string pfx) { prefix = pfx; }

   void Update(MARKET_MODE mode, double rangeScore, double trendScore, double atr,
               double gapBuy, double gapSell, int buyCnt, int sellCnt,
               double buyProfit, double sellProfit, double floatDD, double marginPct,
               double hedgeBuyVol, double hedgeSellVol, double dailyProfitPct, double dailyLossFloor,
               string session, long spread, double volFactor)
   {
      int y=20, dy=16, x=10;
      color hdr = clrKhaki;
      Label("t0","== Adaptive Grid Engine ==",x,y,hdr,10); y+=dy+4;
      Label("mode","Mode: "+ModeToString(mode), x,y, (mode==MODE_TRANSITION?clrSilver:(mode==MODE_TREND_UP?clrLime:(mode==MODE_TREND_DOWN?clrTomato:clrAqua))) ); y+=dy;
      Label("scores", StringFormat("Range Score: %.1f   Trend Score: %.1f", rangeScore, trendScore), x,y,clrWhite); y+=dy;
      Label("atr", StringFormat("ATR: %.2f   VolFactor: %.2f   Session: %s", atr, volFactor, session), x,y,clrWhite); y+=dy;
      Label("gap", StringFormat("Grid Gap  Buy: %.2f   Sell: %.2f", gapBuy, gapSell), x,y,clrWhite); y+=dy;
      Label("baskets", StringFormat("Buy Basket: %d trades  P/L: %.2f", buyCnt, buyProfit), x,y,clrLime); y+=dy;
      Label("baskets2", StringFormat("Sell Basket: %d trades  P/L: %.2f", sellCnt, sellProfit), x,y,clrTomato); y+=dy;
      Label("hedge", StringFormat("Hedge Vol  Buy: %.2f  Sell: %.2f", hedgeBuyVol, hedgeSellVol), x,y,clrOrange); y+=dy;
      Label("dd", StringFormat("Floating DD: %.2f%%   Margin Used: %.1f%%", floatDD, marginPct), x,y, floatDD>5?clrOrangeRed:clrWhite); y+=dy;
      Label("spread", StringFormat("Spread: %d pts", spread), x,y,clrWhite); y+=dy;
      Label("daily", StringFormat("Daily P/L: %.2f%%  (loss cap %.2f%%)", dailyProfitPct, dailyLossFloor), x,y, dailyProfitPct<0?clrOrangeRed:clrLime); y+=dy;
   }
};

//====================================================================
// GLOBAL MODULE INSTANCES
//====================================================================
CMarketClassifier g_classifier;
CVolatilityEngine g_volatility;
CSessionEngine    g_session;
CStatisticsEngine g_stats;
CGridEngine       g_grid;
CMoneyManager     g_mm;
CBasketManager    g_basket;
CHedgeEngine      g_hedge;
CRiskManager      g_risk;
CDashboard        g_dash;

//====================================================================
// OnInit
//====================================================================
int OnInit()
{
   hATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   hADX = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
   hEMA = iMA(_Symbol, PERIOD_CURRENT, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hBB  = iBands(_Symbol, PERIOD_CURRENT, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);

   if(hATR==INVALID_HANDLE || hADX==INVALID_HANDLE || hEMA==INVALID_HANDLE || hBB==INVALID_HANDLE)
   {
      Print("Failed to create indicator handle(s).");
      return(INIT_FAILED);
   }

   g_classifier.Init();
   g_stats.Init();
   g_basket.Init(&g_grid, &g_mm);
   g_hedge.Init(&g_basket, &g_mm);
   g_risk.Init();
   g_dash.Init("AGE_");

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStamp = TimeCurrent() - (TimeCurrent()%86400);

   trade.SetTypeFillingBySymbol(_Symbol);

   return(INIT_SUCCEEDED);
}

//====================================================================
// OnDeinit
//====================================================================
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, "AGE_");
}

//====================================================================
// Helper: reset daily equity baseline at server-day rollover
//====================================================================
void CheckDayRollover()
{
   datetime today = TimeCurrent() - (TimeCurrent()%86400);
   if(today != g_dayStamp)
   {
      g_dayStamp = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

//====================================================================
// OnTick
//====================================================================
void OnTick()
{
   CheckDayRollover();

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   g_risk.CheckEmergency(equity, balance, g_dayStartEquity);
   if(g_risk.emergencyStop)
   {
      // Manage-only mode: no new trades, optionally could force-close here.
      Comment("EMERGENCY STOP ACTIVE - new entries disabled. Manage existing baskets manually.");
   }

   //--- detect new bar
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (t != lastBarTime);
   if(isNewBar) lastBarTime = t;

   //--- pull indicator buffers (only need refresh each tick for ATR-based gap calc)
   double atrBuf[100], adxBuf[100], plusDI[100], minusDI[100];
   double emaBuf[100], bbUpper[100], bbLower[100];
   double closeBuf[100], highBuf[100], lowBuf[100], openBuf[100];

   int need = 60;
   if(CopyBuffer(hATR,0,0,need,atrBuf) <= 0) return;
   if(CopyBuffer(hADX,0,0,need,adxBuf) <= 0) return;
   if(CopyBuffer(hADX,1,0,need,plusDI) <= 0) return;
   if(CopyBuffer(hADX,2,0,need,minusDI) <= 0) return;
   if(CopyBuffer(hEMA,0,0,need,emaBuf) <= 0) return;
   if(CopyBuffer(hBB,1,0,need,bbUpper) <= 0) return; // upper band
   if(CopyBuffer(hBB,2,0,need,bbLower) <= 0) return; // lower band
   if(CopyClose(_Symbol,PERIOD_CURRENT,0,need,closeBuf) <= 0) return;
   if(CopyHigh(_Symbol,PERIOD_CURRENT,0,need,highBuf) <= 0) return;
   if(CopyLow(_Symbol,PERIOD_CURRENT,0,need,lowBuf) <= 0) return;
   if(CopyOpen(_Symbol,PERIOD_CURRENT,0,need,openBuf) <= 0) return;

   // indicator arrays come back oldest->newest by default index 0 = most recent
   // (CopyBuffer/CopySeries with default AS_SERIES=true on these arrays)
   ArraySetAsSeries(atrBuf,true); ArraySetAsSeries(adxBuf,true);
   ArraySetAsSeries(plusDI,true); ArraySetAsSeries(minusDI,true);
   ArraySetAsSeries(emaBuf,true); ArraySetAsSeries(bbUpper,true); ArraySetAsSeries(bbLower,true);
   ArraySetAsSeries(closeBuf,true); ArraySetAsSeries(highBuf,true);
   ArraySetAsSeries(lowBuf,true); ArraySetAsSeries(openBuf,true);

   g_volatility.Update(atrBuf, need);

   MARKET_MODE mode = g_classifier.Confirmed();
   if(isNewBar)
   {
      mode = g_classifier.Evaluate(adxBuf, plusDI, minusDI, atrBuf, bbUpper, bbLower,
                                    emaBuf, closeBuf, highBuf, lowBuf, openBuf, need);
      g_stats.OnNewBar(mode);
   }

   //--- Safety: abnormal conditions -> disable new entries, manage only
   bool abnormal = g_volatility.IsAbnormal(InpAbnormalATRMult);
   long curSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   double floatDD = g_risk.FloatingDrawdownPct(balance);
   double sessionMult = g_session.GapMultiplier();
   double durationFeedback = g_stats.RangeDurationFeedback();

   bool buyIsDefensive  = (mode==MODE_TREND_DOWN);
   bool sellIsDefensive = (mode==MODE_TREND_UP);

   double gapBuy  = g_grid.ComputeGap(mode, buyIsDefensive,  atrBuf[0], g_volatility.volFactor, sessionMult, floatDD) * durationFeedback;
   double gapSell = g_grid.ComputeGap(mode, sellIsDefensive, atrBuf[0], g_volatility.volFactor, sessionMult, floatDD) * durationFeedback;

   int maxBuy  = g_grid.MaxTradesForMode(mode, buyIsDefensive);
   int maxSell = g_grid.MaxTradesForMode(mode, sellIsDefensive);

   bool canOpen = g_risk.CanOpenNewTrades(equity, balance, g_dayStartEquity) && !abnormal;

   //--- Entry logic per mode (only act on new bar to avoid over-trading intrabar noise
   //    for basket TP checks we still run every tick, entries only on new bar)
   if(isNewBar && canOpen)
   {
      switch(mode)
      {
         case MODE_RANGE_STRONG:
         case MODE_RANGE_WEAK:
            g_basket.TryGridEntry(true,  InpMagicBuy,  gapBuy,  maxBuy,  InpTradeComment+"_R_BUY");
            g_basket.TryGridEntry(false, InpMagicSell, gapSell, maxSell, InpTradeComment+"_R_SELL");
            break;

         case MODE_TREND_UP:
            g_basket.TryGridEntry(true,  InpMagicBuy,  gapBuy,  maxBuy,  InpTradeComment+"_TU_BUY");
            g_basket.TryGridEntry(false, InpMagicSell, gapSell, maxSell, InpTradeComment+"_TU_SELLDEF");
            break;

         case MODE_TREND_DOWN:
            g_basket.TryGridEntry(false, InpMagicSell, gapSell, maxSell, InpTradeComment+"_TD_SELL");
            g_basket.TryGridEntry(true,  InpMagicBuy,  gapBuy,  maxBuy,  InpTradeComment+"_TD_BUYDEF");
            break;

         case MODE_TRANSITION:
         default:
            // no new baskets - manage existing only
            break;
      }
   }

   //--- Basket exit management (every tick)
   double baseTargetBuy, baseTargetSell;
   switch(mode)
   {
      case MODE_RANGE_STRONG: baseTargetBuy=baseTargetSell=InpBasketProfitRange; break;
      case MODE_RANGE_WEAK:   baseTargetBuy=baseTargetSell=InpBasketProfitWeakRange; break;
      default:                 baseTargetBuy=baseTargetSell=InpBasketProfitTrend; break;
   }
   g_basket.ManageBasketExit(InpMagicBuy,  baseTargetBuy,  g_volatility.volFactor, 0);
   g_basket.ManageBasketExit(InpMagicSell, baseTargetSell, g_volatility.volFactor, 1);

   //--- Hedge engine (every tick)
   g_hedge.Manage(InpMagicBuy,  InpMagicHedgeSell, true,  g_classifier.trendScore, atrBuf[0], equity, balance);
   g_hedge.Manage(InpMagicSell, InpMagicHedgeBuy,  false, g_classifier.trendScore, atrBuf[0], equity, balance);

   //--- Dashboard
   if(InpShowDashboard)
   {
      double marginPct = 0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq>0) marginPct = AccountInfoDouble(ACCOUNT_MARGIN)/eq*100.0;

      g_dash.Update(mode, g_classifier.rangeScore, g_classifier.trendScore, atrBuf[0],
                    gapBuy, gapSell,
                    g_basket.CountPositions(InpMagicBuy), g_basket.CountPositions(InpMagicSell),
                    g_basket.SumProfit(InpMagicBuy), g_basket.SumProfit(InpMagicSell),
                    floatDD, marginPct,
                    g_basket.SumVolume(InpMagicHedgeBuy), g_basket.SumVolume(InpMagicHedgeSell),
                    g_risk.DailyProfitPct(equity, g_dayStartEquity), -InpMaxDailyDrawdownPct,
                    g_session.Name(), curSpread, g_volatility.volFactor);
   }
}
//+------------------------------------------------------------------+
