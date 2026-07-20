//+------------------------------------------------------------------+
//|                                      SystemicContagionEA.mq5      |
//|                                                                    |
//|  Inspired by: Feinstein, Z. & Sojmark, A. (2026)                  |
//|  "Endogenous Distress Contagion in a Dynamic Interbank Model:     |
//|   How Possible Future Losses May Spell Doom Today"                |
//|  Mathematical Finance, 36(3), 595-619.                             |
//|                                                                    |
//|  CONCEPT                                                           |
//|  --------                                                          |
//|  A basket of correlated symbols is treated as a small "interbank   |
//|  network". Each symbol has a Black-Cox style barrier survival      |
//|  probability (probability price stays above a distress barrier    |
//|  over a horizon). These are iterated through a correlation-        |
//|  weighted fixed-point update -- a direct analogue of the paper's   |
//|  clearing map Psi^T -- to obtain a NETWORK-ADJUSTED survival       |
//|  probability per symbol. A drop in that quantity (own or           |
//|  network-wide) increases a "distress multiplier" that shrinks      |
//|  position size and widens stops (the paper's endogenous            |
//|  stochastic-volatility / down-market effect). A short vs. long      |
//|  horizon comparison of survival probabilities gives an implied     |
//|  term structure; an inverted "curve" throttles new entries         |
//|  entirely, echoing the paper's finding that inverted systemic      |
//|  yield curves are a stress signature.                              |
//|                                                                    |
//|  This EA is a conceptual translation of an academic interbank      |
//|  contagion model into a trading risk filter. It is NOT a           |
//|  reproduction of the paper's clearing equilibrium and should be    |
//|  tested thoroughly before any live use.                            |
//+------------------------------------------------------------------+
#property copyright "Educational / research use"
#property version   "1.01"
#property strict

//====================================================================
//  INPUTS
//====================================================================
input string InpBasketSymbols   = "EURUSD,GBPUSD,AUDUSD,USDCHF,USDJPY"; // Network basket (comma-separated)
input ENUM_TIMEFRAMES InpTF     = PERIOD_H1;   // Timeframe for returns / volatility
input int    InpVolLookback     = 100;         // Bars used to estimate volatility & drift
input int    InpCorrLookback    = 100;         // Bars used to estimate correlation matrix
input double InpBarrierATRMult  = 6.0;         // Distress barrier = price -/+ ATR * this multiple (was 3.0 -- too tight, gave ~50% survival even in calm markets)
input int    InpATRPeriod       = 14;          // ATR period for the barrier distance
input double InpContagionBlend  = 0.35;        // Weight given to neighbors in fixed-point update (0-1)
input int    InpFixedPointIters = 25;          // Number of Picard iterations for the contagion map
input int    InpNetworkHorizonBars = 12;       // Horizon (in InpTF bars) for the network survival gate
input int    InpShortVolLookback = 20;         // "Recent" volatility window (bars) -- numerator of the stress ratio
input int    InpLongVolLookback  = 200;        // "Baseline" volatility window (bars) -- denominator of the stress ratio
input double InpVolStressRatio   = 1.35;       // If recent/baseline vol ratio exceeds this, treat the symbol as in a stressed regime
input bool   InpUseEstimatedDrift = false;     // If false (recommended), survival probs assume zero drift -- far more stable than a noisy sample mean
input double InpMinNetworkSurv   = 0.35;       // Below this network survival prob -> no new trades (was 0.55 -- too close to "normal" territory)
input double InpBaseLot         = 0.10;        // Base lot size before distress adjustment
input double InpBaseStopPips    = 30.0;        // Base stop-loss distance in pips before adjustment
input double InpBaseTPPips      = 45.0;        // Base take-profit distance in pips
input int    InpMagic           = 20260721;    // Magic number
input int    InpMAFastPeriod    = 10;          // Simple trend filter: fast MA
input int    InpMASlowPeriod    = 50;          // Simple trend filter: slow MA
input int    InpMaxDistressCap  = 3;           // Cap on distress multiplier (1..N)

//====================================================================
//  GLOBALS
//====================================================================
string   g_symbols[];
int      g_nSymbols = 0;

double   g_corr[];             // flattened n x n correlation matrix: g_corr[i*n+j]
double   g_ownSurv[];           // each symbol's own barrier survival probability
double   g_netSurv[];           // network-adjusted (contagion) survival probability
double   g_barrier[];           // distress barrier level per symbol
double   g_vol[];               // per-bar return volatility per symbol
double   g_drift[];             // per-bar return drift per symbol

int      g_atrHandles[];        // one ATR handle per basket symbol
int      g_maFastHandle = INVALID_HANDLE;   // fast MA handle, chart symbol only
int      g_maSlowHandle = INVALID_HANDLE;   // slow MA handle, chart symbol only

int      g_thisSymbolIndex = -1;

//+------------------------------------------------------------------+
//| Utility: standard normal CDF                                       |
//+------------------------------------------------------------------+
double NormalCDF(double x)
{
   // Abramowitz & Stegun approximation
   double k = 1.0 / (1.0 + 0.2316419 * MathAbs(x));
   double kSum = k*(0.319381530 + k*(-0.356563782 + k*(1.781477937 +
                 k*(-1.821255978 + k*1.330274429))));
   double cdf = 1.0 - (1.0/MathSqrt(2.0*M_PI)) * MathExp(-x*x/2.0) * kSum;
   return (x >= 0.0) ? cdf : 1.0 - cdf;
}

//+------------------------------------------------------------------+
//| Black-Cox style barrier survival probability                       |
//|                                                                    |
//| Probability that a log-price process X_t = ln(price) + drift*t     |
//| + vol*W_t never falls to ln(barrier) over horizon T.                |
//|                                                                    |
//| IMPORTANT UNIT CONVENTION: 'vol' and 'drift' must be estimated in   |
//| the SAME time unit as 'T' (here: per bar of InpTF, with T expressed |
//| as a number of bars). Mixing a per-bar vol with a T expressed in    |
//| years (or vice versa) makes d_A/d_B blow up and the result          |
//| degenerate to 0 or 1 almost everywhere -- that was the bug in the   |
//| earlier version of this EA.                                        |
//|                                                                    |
//| Closed form (standard Brownian-motion-with-drift reflection         |
//| identity, equivalent to the barrier term used in Black & Cox 1976   |
//| and referenced in Feinstein & Sojmark, Remark 2.6):                 |
//|                                                                    |
//|   d_A = (lnRatio + drift*T) / (vol*sqrt(T))                         |
//|   d_B = (-lnRatio + drift*T) / (vol*sqrt(T))                        |
//|   survival = N(d_A) - (barrier/price)^(2*drift/vol^2) * N(d_B)      |
//|                                                                    |
//| where lnRatio = ln(price/barrier) > 0. With drift = 0 this reduces  |
//| to the classic reflection-principle result 2*N(a)-1.                |
//+------------------------------------------------------------------+
double SurvivalProbability(double price, double barrier, double vol,
                            double drift, double T)
{
   if(barrier >= price || vol <= 0.0 || T <= 0.0) return 0.0;

   double lnRatio = MathLog(price/barrier);
   double sqrtT   = MathSqrt(T);

   double dA = (lnRatio + drift*T) / (vol*sqrtT);
   double dB = (-lnRatio + drift*T) / (vol*sqrtT);

   double nA = NormalCDF(dA);
   double nB = NormalCDF(dB);

   double survival;
   if(MathAbs(drift) < 1e-12)
   {
      // Zero-drift case: exponent is 0, correction term is exactly 1.
      survival = nA - nB;
   }
   else
   {
      double exponent  = 2.0*drift/(vol*vol);
      double correction = MathPow(barrier/price, exponent) * nB;
      survival = nA - correction;
   }

   return MathMax(0.0, MathMin(1.0, survival));
}

//+------------------------------------------------------------------+
//| Split comma-separated symbol string into array, trimmed            |
//+------------------------------------------------------------------+
void SplitSymbols(string list, string &out[])
{
   ushort sep = StringGetCharacter(",", 0);
   int n = StringSplit(list, sep, out);
   for(int i=0; i<n; i++)
   {
      StringTrimLeft(out[i]);
      StringTrimRight(out[i]);
   }
}

//+------------------------------------------------------------------+
//| One-time-per-symbol diagnostic: this is THE most common reason a   |
//| multi-symbol EA silently never trades in the Strategy Tester --    |
//| MT5 only guarantees local history for the chart's own symbol.      |
//| Other basket symbols need their history downloaded in the terminal |
//| (Market Watch -> right click symbol -> Symbols -> or just open a   |
//| chart of each basket symbol and scroll back to the test start      |
//| date at least once) BEFORE running the backtest.                   |
//+------------------------------------------------------------------+
bool g_warnedHistory[];

void WarnInsufficientHistory(string sym, int copied, int needed)
{
   int idx = -1;
   for(int i=0; i<g_nSymbols; i++)
      if(g_symbols[i]==sym) idx=i;
   if(idx<0) return;
   if(idx < ArraySize(g_warnedHistory) && g_warnedHistory[idx]) return; // already warned once

   if(idx >= ArraySize(g_warnedHistory)) ArrayResize(g_warnedHistory, g_nSymbols);
   g_warnedHistory[idx] = true;

   Print("SystemicContagionEA: NOT ENOUGH HISTORY for basket symbol '", sym,
         "' at this point in the test -- got ", copied, " bars, needed ", needed,
         ". This symbol's data is not yet loaded/available in the terminal for this ",
         "period. The EA will keep skipping ALL entries until every basket symbol has ",
         "enough history. Fix: open a chart for '", sym, "' in the terminal (not just the ",
         "tester) and scroll/Ctrl+Home back to (or before) the backtest start date so MT5 ",
         "downloads/caches the history, then re-run the test.");
}

//+------------------------------------------------------------------+
//| Estimate log-return volatility (per bar) and drift for a symbol    |
//+------------------------------------------------------------------+
bool EstimateVolDrift(string sym, int lookback, double &volOut, double &driftOut)
{
   double closes[];
   ArraySetAsSeries(closes, true);
   int copied = CopyClose(sym, InpTF, 0, lookback+2, closes);
   if(copied < lookback+2)
   {
      WarnInsufficientHistory(sym, copied, lookback+2);
      return false;
   }

   double rets[];
   ArrayResize(rets, lookback);
   for(int i=0; i<lookback; i++)
      rets[i] = MathLog(closes[i]/closes[i+1]);

   double mean = 0.0;
   for(int i=0; i<lookback; i++) mean += rets[i];
   mean /= lookback;

   double var = 0.0;
   for(int i=0; i<lookback; i++) var += (rets[i]-mean)*(rets[i]-mean);
   var /= MathMax(1, lookback-1);

   volOut   = MathSqrt(var);
   driftOut = mean;
   return true;
}

//+------------------------------------------------------------------+
//| Log-return series for one symbol (used to build the correlations)  |
//+------------------------------------------------------------------+
bool GetLogReturns(string sym, int lookback, double &retOut[])
{
   double closes[];
   ArraySetAsSeries(closes, true);
   int copied = CopyClose(sym, InpTF, 0, lookback+2, closes);
   if(copied < lookback+2)
   {
      WarnInsufficientHistory(sym, copied, lookback+2);
      return false;
   }

   ArrayResize(retOut, lookback);
   for(int b=0; b<lookback; b++)
      retOut[b] = MathLog(closes[b]/closes[b+1]);
   return true;
}

//+------------------------------------------------------------------+
//| Pearson correlation between two return series                      |
//+------------------------------------------------------------------+
double PearsonCorrelation(const double &a[], const double &b[], int n)
{
   double meanA=0.0, meanB=0.0;
   for(int i=0;i<n;i++){ meanA+=a[i]; meanB+=b[i]; }
   meanA/=n; meanB/=n;

   double cov=0.0, varA=0.0, varB=0.0;
   for(int i=0;i<n;i++)
   {
      double da=a[i]-meanA, db=b[i]-meanB;
      cov  += da*db;
      varA += da*da;
      varB += db*db;
   }
   if(varA<=0.0 || varB<=0.0) return 0.0;
   return cov / MathSqrt(varA*varB);
}

//+------------------------------------------------------------------+
//| Build the exposure (correlation) network across the basket.        |
//| Stored as a flattened n x n array: g_corr[i*n + j].                 |
//| (MQL5 only supports a dynamic FIRST dimension, so a true double     |
//|  corr[][] cannot be resized at runtime -- flattening avoids that.)  |
//+------------------------------------------------------------------+
bool BuildCorrelationMatrix(int lookback)
{
   int n = g_nSymbols;
   ArrayResize(g_corr, n*n);

   // Cache each symbol's return series in a flattened buffer:
   // symbol i occupies allReturns[i*lookback .. i*lookback+lookback-1]
   double allReturns[];
   ArrayResize(allReturns, n*lookback);

   for(int i=0; i<n; i++)
   {
      double tmp[];
      if(!GetLogReturns(g_symbols[i], lookback, tmp)) return false;
      for(int b=0; b<lookback; b++)
         allReturns[i*lookback+b] = tmp[b];
   }

   for(int i=0; i<n; i++)
   {
      for(int j=0; j<n; j++)
      {
         if(i==j) { g_corr[i*n+j] = 1.0; continue; }

         double a[], b[];
         ArrayResize(a, lookback);
         ArrayResize(b, lookback);
         for(int k=0; k<lookback; k++)
         {
            a[k] = allReturns[i*lookback+k];
            b[k] = allReturns[j*lookback+k];
         }
         g_corr[i*n+j] = PearsonCorrelation(a, b, lookback);
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Fixed-point contagion update (analogue of the paper's Psi^T map)   |
//+------------------------------------------------------------------+
void ContagionFixedPoint()
{
   int n = g_nSymbols;
   ArrayResize(g_netSurv, n);
   ArrayCopy(g_netSurv, g_ownSurv);

   double tmp[];
   ArrayResize(tmp, n);

   for(int it=0; it<InpFixedPointIters; it++)
   {
      for(int i=0; i<n; i++)
      {
         double weightedNeighbor = 0.0, weightSum = 0.0;
         for(int j=0; j<n; j++)
         {
            if(j==i) continue;
            double w = MathAbs(g_corr[i*n+j]); // |correlation| plays the role of L_ij exposure
            weightedNeighbor += w * g_netSurv[j];
            weightSum        += w;
         }
         double neighborAvg = (weightSum > 0.0) ? weightedNeighbor/weightSum : g_ownSurv[i];
         tmp[i] = (1.0 - InpContagionBlend)*g_ownSurv[i] + InpContagionBlend*neighborAvg;
      }
      ArrayCopy(g_netSurv, tmp);
   }
}

//+------------------------------------------------------------------+
//| Read current ATR value for basket symbol idx (via handle+buffer)   |
//+------------------------------------------------------------------+
double GetATRValue(int idx)
{
   if(g_atrHandles[idx] == INVALID_HANDLE)
   {
      static bool warned[];
      if(idx >= ArraySize(warned)) ArrayResize(warned, g_nSymbols);
      if(!warned[idx])
      {
         warned[idx] = true;
         Print("SystemicContagionEA: ATR handle invalid for basket symbol '", g_symbols[idx], "'.");
      }
      return 0.0;
   }

   double buf[];
   ArraySetAsSeries(buf, true);
   int got = CopyBuffer(g_atrHandles[idx], 0, 0, 1, buf);
   if(got <= 0)
   {
      static bool warnedBuf[];
      if(idx >= ArraySize(warnedBuf)) ArrayResize(warnedBuf, g_nSymbols);
      if(!warnedBuf[idx])
      {
         warnedBuf[idx] = true;
         Print("SystemicContagionEA: ATR buffer not ready yet for '", g_symbols[idx],
               "' (CopyBuffer returned ", got, "). This resolves itself once the ",
               "indicator has enough history; the EA will keep retrying each bar.");
      }
      return 0.0;
   }
   return buf[0];
}

//+------------------------------------------------------------------+
//| Recompute barriers, own survival probabilities, and run contagion  |
//+------------------------------------------------------------------+
bool RefreshNetworkState()
{
   ArrayResize(g_vol, g_nSymbols);
   ArrayResize(g_drift, g_nSymbols);
   ArrayResize(g_barrier, g_nSymbols);
   ArrayResize(g_ownSurv, g_nSymbols);

   for(int i=0; i<g_nSymbols; i++)
   {
      double vol, drift;
      if(!EstimateVolDrift(g_symbols[i], InpVolLookback, vol, drift)) return false;
      g_vol[i]   = vol;
      g_drift[i] = drift;

      double atr = GetATRValue(i);
      if(atr <= 0.0) return false;

      double price = SymbolInfoDouble(g_symbols[i], SYMBOL_BID);
      g_barrier[i] = price - InpBarrierATRMult * atr; // "capital-zero" analogue

      // vol/drift are per-bar (InpTF) statistics, so the horizon T must also be
      // expressed as a number of bars -- NOT years, NOT "1 window" -- for the
      // formula's units to be consistent. See SurvivalProbability() header comment.
      double T = (double)InpNetworkHorizonBars;
      double effectiveDrift = InpUseEstimatedDrift ? g_drift[i] : 0.0;
      g_ownSurv[i] = SurvivalProbability(price, g_barrier[i], g_vol[i], effectiveDrift, T);
   }

   if(!BuildCorrelationMatrix(InpCorrLookback)) return false;
   ContagionFixedPoint();
   return true;
}

//+------------------------------------------------------------------+
//| Distress multiplier: paper's endogenous stochastic-volatility      |
//| / down-market effect, translated into risk sizing                  |
//+------------------------------------------------------------------+
double DistressMultiplier(double networkSurvivalProb)
{
   double distress = 1.0 - networkSurvivalProb;
   double multiplier = 1.0 + (double)(InpMaxDistressCap-1) * MathPow(distress, 2.0);
   return MathMin(multiplier, (double)InpMaxDistressCap);
}

//+------------------------------------------------------------------+
//| Volatility-regime stress check (replaces the earlier               |
//| "term structure inversion" attempt).                                |
//|                                                                    |
//| WHY THE ORIGINAL APPROACH WAS REPLACED: comparing a short-horizon   |
//| vs. long-horizon barrier survival probability under a driftless     |
//| random walk is structurally doomed to look "inverted" almost         |
//| always. A zero-drift Brownian motion is recurrent -- it hits ANY     |
//| fixed barrier with probability 1 given enough time -- so extending   |
//| the same barrier out to a much longer horizon mechanically drives    |
//| the long-horizon survival probability toward 0 regardless of         |
//| whether the market is actually calm or stressed. That produced        |
//| "inverted" on essentially every bar, which is a math artifact, not    |
//| a market signal.                                                     |
//|                                                                    |
//| REPLACEMENT: compare RECENT realized volatility (short lookback,     |
//| e.g. last 20 bars) to BASELINE realized volatility (long lookback,   |
//| e.g. last 200 bars) for the same symbol. A ratio well above 1 means   |
//| the market has gotten noticeably more volatile than its own recent   |
//| history -- a direct, numerically robust proxy for the paper's         |
//| volatility-clustering / down-market effect, without any horizon      |
//| extrapolation blow-up.                                               |
//+------------------------------------------------------------------+
bool IsVolatilityRegimeStressed(string sym, double &ratioOut)
{
   double volShort, driftShort, volLong, driftLong;

   if(!EstimateVolDrift(sym, InpShortVolLookback, volShort, driftShort)) { ratioOut=1.0; return false; }
   if(!EstimateVolDrift(sym, InpLongVolLookback,  volLong,  driftLong )) { ratioOut=1.0; return false; }

   if(volLong <= 0.0) { ratioOut=1.0; return false; }

   ratioOut = volShort / volLong;
   return (ratioOut > InpVolStressRatio);
}

//+------------------------------------------------------------------+
//| Simple trend core signal (fast/slow MA) -- the "strategy" the      |
//| risk engine is wrapped around. Swap this out freely.               |
//+------------------------------------------------------------------+
int TrendSignal()
{
   if(g_maFastHandle == INVALID_HANDLE || g_maSlowHandle == INVALID_HANDLE) return 0;

   double fastBuf[], slowBuf[];
   ArraySetAsSeries(fastBuf, true);
   ArraySetAsSeries(slowBuf, true);

   if(CopyBuffer(g_maFastHandle, 0, 0, 2, fastBuf) < 2) return 0;
   if(CopyBuffer(g_maSlowHandle, 0, 0, 2, slowBuf) < 2) return 0;

   double maFast = fastBuf[0], maFastPrev = fastBuf[1];
   double maSlow = slowBuf[0], maSlowPrev = slowBuf[1];

   if(maFastPrev <= maSlowPrev && maFast > maSlow) return 1;  // bullish cross
   if(maFastPrev >= maSlowPrev && maFast < maSlow) return -1; // bearish cross
   return 0;
}

//+------------------------------------------------------------------+
//| Pip size helper                                                     |
//+------------------------------------------------------------------+
double PipSize(string sym)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   return (digits==3 || digits==5) ? point*10.0 : point;
}

//+------------------------------------------------------------------+
//| Count open positions for a symbol under this EA's magic number     |
//+------------------------------------------------------------------+
bool HasOpenPosition(string sym)
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==sym &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Pick a filling mode the symbol/broker actually supports. Hard-      |
//| coding ORDER_FILLING_FOK breaks on brokers/symbols that only offer  |
//| IOC or Return, which is exactly the "Unsupported filling mode"      |
//| error. We read SYMBOL_FILLING_MODE and prefer FOK > IOC > RETURN.   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetSupportedFilling(string sym)
{
   int mode = (int)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);

   if((mode & SYMBOL_FILLING_FOK) != 0)  return ORDER_FILLING_FOK;
   if((mode & SYMBOL_FILLING_IOC) != 0)  return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN; // safest fallback, works even when the flags report nothing
}

//+------------------------------------------------------------------+
//| Execute a market order sized and stopped according to distress     |
//+------------------------------------------------------------------+
void ExecuteTrade(string sym, int direction, double distressMult)
{
   double pip = PipSize(sym);
   double lot = NormalizeDouble(InpBaseLot / distressMult, 2);
   double minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(lot < minLot) lot = minLot;

   double stopPips = InpBaseStopPips * distressMult; // widen stop under distress
   double tpPips   = InpBaseTPPips;                  // TP left unscaled (asymmetric by design)

   double price = (direction>0) ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                 : SymbolInfoDouble(sym, SYMBOL_BID);
   double sl = (direction>0) ? price - stopPips*pip : price + stopPips*pip;
   double tp = (direction>0) ? price + tpPips*pip   : price - tpPips*pip;

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = sym;
   request.volume       = lot;
   request.type         = (direction>0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price        = price;
   request.sl           = NormalizeDouble(sl, digits);
   request.tp           = NormalizeDouble(tp, digits);
   request.deviation    = 10;
   request.magic        = InpMagic;
   request.type_filling = GetSupportedFilling(sym);
   request.comment      = "ContagionEA d="+DoubleToString(distressMult,2);

   if(!OrderSend(request, result))
   {
      Print("SystemicContagionEA: OrderSend failed, error=", GetLastError(),
            " retcode=", result.retcode, " filling=", EnumToString(request.type_filling));

      // Fallback: if the chosen filling mode was still rejected, retry once with RETURN,
      // which virtually every broker/symbol accepts.
      if(request.type_filling != ORDER_FILLING_RETURN)
      {
         request.type_filling = ORDER_FILLING_RETURN;
         ZeroMemory(result);
         if(!OrderSend(request, result))
            Print("SystemicContagionEA: retry with ORDER_FILLING_RETURN also failed, error=",
                  GetLastError(), " retcode=", result.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| Release all indicator handles                                      |
//+------------------------------------------------------------------+
void ReleaseHandles()
{
   for(int i=0; i<ArraySize(g_atrHandles); i++)
      if(g_atrHandles[i] != INVALID_HANDLE) IndicatorRelease(g_atrHandles[i]);

   if(g_maFastHandle != INVALID_HANDLE) IndicatorRelease(g_maFastHandle);
   if(g_maSlowHandle != INVALID_HANDLE) IndicatorRelease(g_maSlowHandle);
}

//+------------------------------------------------------------------+
//| Expert initialization                                               |
//+------------------------------------------------------------------+
int OnInit()
{
   SplitSymbols(InpBasketSymbols, g_symbols);
   g_nSymbols = ArraySize(g_symbols);

   if(g_nSymbols < 2)
   {
      Print("SystemicContagionEA: need at least 2 symbols in the basket to build a network.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_thisSymbolIndex = -1;
   for(int i=0; i<g_nSymbols; i++)
      if(g_symbols[i]==_Symbol) g_thisSymbolIndex = i;

   if(g_thisSymbolIndex < 0)
   {
      Print("SystemicContagionEA: chart symbol ", _Symbol,
            " is not part of InpBasketSymbols. Add it to trade on this chart.");
      return INIT_PARAMETERS_INCORRECT;
   }

   for(int i=0; i<g_nSymbols; i++)
      SymbolSelect(g_symbols[i], true);

   // --- Create one ATR handle per basket symbol ---
   ArrayResize(g_atrHandles, g_nSymbols);
   for(int i=0; i<g_nSymbols; i++)
   {
      g_atrHandles[i] = iATR(g_symbols[i], InpTF, InpATRPeriod);
      if(g_atrHandles[i] == INVALID_HANDLE)
      {
         Print("SystemicContagionEA: failed to create ATR handle for ", g_symbols[i]);
         return INIT_FAILED;
      }
   }

   // --- Create fast/slow MA handles for the chart symbol only ---
   g_maFastHandle = iMA(_Symbol, InpTF, InpMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_maSlowHandle = iMA(_Symbol, InpTF, InpMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_maFastHandle == INVALID_HANDLE || g_maSlowHandle == INVALID_HANDLE)
   {
      Print("SystemicContagionEA: failed to create MA handles.");
      return INIT_FAILED;
   }

   if(!RefreshNetworkState())
   {
      Print("SystemicContagionEA: initial network state could not be built ",
            "(insufficient history or indicators not ready yet -- will retry on next tick).");
      // Not fatal: indicator buffers may simply not be filled yet on attach.
   }

   Print("SystemicContagionEA initialized on ", g_nSymbols, " symbols. Trading symbol index = ",
         g_thisSymbolIndex);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastBarTime = 0;
   static int      barCounter  = 0;
   static int      refreshFailCounter = 0;

   datetime curBarTime = iTime(_Symbol, InpTF, 0);
   if(curBarTime == lastBarTime) return; // act once per closed bar
   lastBarTime = curBarTime;
   barCounter++;

   if(!RefreshNetworkState())
   {
      refreshFailCounter++;
      // Throttled: print every 50 failed bars so the Journal isn't flooded, but the
      // problem stays visible instead of the EA going completely silent.
      if(refreshFailCounter % 50 == 1)
         Print("SystemicContagionEA: RefreshNetworkState() has failed on ", refreshFailCounter,
               " bar(s) so far (current bar time ", TimeToString(curBarTime),
               "). See earlier warnings above for the specific symbol/reason. ",
               "No trades can be evaluated until this resolves.");
      return;
   }

   double mySurv       = g_ownSurv[g_thisSymbolIndex];
   double myNetSurv    = g_netSurv[g_thisSymbolIndex];
   double volRatio     = 1.0;
   bool   stressed      = IsVolatilityRegimeStressed(_Symbol, volRatio);
   double distressMult = DistressMultiplier(myNetSurv);

   Comment(StringFormat(
      "SystemicContagionEA\n"
      "Symbol: %s\n"
      "Own survival prob:      %.4f\n"
      "Network-adjusted prob:  %.4f\n"
      "Vol regime stressed:    %s (ratio %.2fx, threshold %.2fx)\n"
      "Distress multiplier:    %.2fx\n"
      "Min network threshold:  %.2f",
      _Symbol, mySurv, myNetSurv, (stressed?"YES":"no"), volRatio, InpVolStressRatio,
      distressMult, InpMinNetworkSurv));

   // Periodic numeric snapshot in the Journal (not just Comment(), which the Strategy
   // Tester report does not capture), so the full time series can be inspected later.
   if(barCounter % 200 == 1)
      Print("SystemicContagionEA: [", TimeToString(curBarTime), "] ", _Symbol,
            " ownSurv=", DoubleToString(mySurv,4),
            " netSurv=", DoubleToString(myNetSurv,4),
            " volRatio=", DoubleToString(volRatio,2),
            " stressed=", (stressed?"yes":"no"),
            " distressMult=", DoubleToString(distressMult,2));

   // --- Risk gate: paper's core message -- don't wait for an actual default ---
   if(myNetSurv < InpMinNetworkSurv)
   {
      Print("SystemicContagionEA: network survival probability ", DoubleToString(myNetSurv,4),
            " below threshold ", InpMinNetworkSurv, " -- skipping new entries this bar.");
      return;
   }
   if(stressed)
   {
      Print("SystemicContagionEA: volatility regime stressed for ", _Symbol,
            " (ratio ", DoubleToString(volRatio,2), " > ", InpVolStressRatio,
            ") -- skipping new entries this bar.");
      return;
   }
   if(HasOpenPosition(_Symbol)) return;

   int signal = TrendSignal();
   if(signal != 0)
      ExecuteTrade(_Symbol, signal, distressMult);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   ReleaseHandles();
}
//+------------------------------------------------------------------+
