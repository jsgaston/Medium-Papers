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
#property version   "1.00"
#property strict

//====================================================================
//  INPUTS
//====================================================================
input string InpBasketSymbols   = "EURUSD,GBPUSD,AUDUSD,USDCHF,USDJPY"; // Network basket (comma-separated)
input ENUM_TIMEFRAMES InpTF     = PERIOD_H1;   // Timeframe for returns / volatility
input int    InpVolLookback     = 100;         // Bars used to estimate volatility & drift
input int    InpCorrLookback    = 100;         // Bars used to estimate correlation matrix
input double InpBarrierATRMult  = 3.0;         // Distress barrier = price -/+ ATR * this multiple
input int    InpATRPeriod       = 14;          // ATR period for the barrier distance
input double InpContagionBlend  = 0.35;        // Weight given to neighbors in fixed-point update (0-1)
input int    InpFixedPointIters = 25;          // Number of Picard iterations for the contagion map
input double InpShortHorizonDays= 5.0;         // Short maturity, in trading days (~1 week)
input double InpLongHorizonDays = 60.0;        // Long maturity, in trading days (~1 quarter)
input double InpMinNetworkSurv  = 0.55;        // Below this network survival prob -> no new trades
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
double   g_corr[][];          // correlation matrix (exposure network)
double   g_ownSurv[];         // each symbol's own barrier survival probability
double   g_netSurv[];         // network-adjusted (contagion) survival probability
double   g_barrier[];         // distress barrier level per symbol
double   g_vol[];             // annualized-ish volatility per symbol
double   g_drift[];           // drift per symbol

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
//| Probability price stays above 'barrier' over horizon T (years)     |
//+------------------------------------------------------------------+
double SurvivalProbability(double price, double barrier, double vol,
                            double drift, double T)
{
   if(barrier >= price || vol <= 0.0 || T <= 0.0) return 0.0;

   double lnRatio  = MathLog(price/barrier);
   double sqrtT    = MathSqrt(T);
   double d1 = (lnRatio + (drift + 0.5*vol*vol)*T) / (vol*sqrtT);
   double d2 = (lnRatio - (drift - 0.5*vol*vol)*T) / (vol*sqrtT);

   double nd1 = NormalCDF(d1);
   double exponent = 2.0*drift/(vol*vol);
   double correction = MathPow(barrier/price, exponent) * NormalCDF(d2);

   double survival = nd1 - correction;
   return MathMax(0.0, MathMin(1.0, survival));
}

//+------------------------------------------------------------------+
//| Split comma-separated symbol string into array                     |
//+------------------------------------------------------------------+
void SplitSymbols(string list, string &out[])
{
   int n = StringSplit(list, ',', out);
   for(int i=0; i<n; i++)
      StringTrimLeft(out[i]), StringTrimRight(out[i]);
}

//+------------------------------------------------------------------+
//| Estimate log-return volatility (per bar) and drift for a symbol    |
//+------------------------------------------------------------------+
bool EstimateVolDrift(string sym, int lookback, double &volOut, double &driftOut)
{
   double closes[];
   ArraySetAsSeries(closes, true);
   int copied = CopyClose(sym, InpTF, 0, lookback+2, closes);
   if(copied < lookback+2) return false;

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
//| Build the exposure (correlation) network across the basket         |
//+------------------------------------------------------------------+
bool BuildCorrelationMatrix(int lookback)
{
   double retMatrix[][];
   ArrayResize(retMatrix, g_nSymbols);

   for(int i=0; i<g_nSymbols; i++)
   {
      double closes[];
      ArraySetAsSeries(closes, true);
      int copied = CopyClose(g_symbols[i], InpTF, 0, lookback+2, closes);
      if(copied < lookback+2) return false;

      ArrayResize(retMatrix[i], lookback);
      for(int b=0; b<lookback; b++)
         retMatrix[i][b] = MathLog(closes[b]/closes[b+1]);
   }

   ArrayResize(g_corr, g_nSymbols);
   for(int i=0; i<g_nSymbols; i++)
   {
      ArrayResize(g_corr[i], g_nSymbols);
      for(int j=0; j<g_nSymbols; j++)
      {
         if(i==j) { g_corr[i][j] = 1.0; continue; }
         g_corr[i][j] = PearsonCorrelation(retMatrix[i], retMatrix[j], lookback);
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Fixed-point contagion update (analogue of the paper's Psi^T map)   |
//+------------------------------------------------------------------+
void ContagionFixedPoint()
{
   ArrayResize(g_netSurv, g_nSymbols);
   ArrayCopy(g_netSurv, g_ownSurv);

   double tmp[];
   ArrayResize(tmp, g_nSymbols);

   for(int it=0; it<InpFixedPointIters; it++)
   {
      for(int i=0; i<g_nSymbols; i++)
      {
         double weightedNeighbor = 0.0, weightSum = 0.0;
         for(int j=0; j<g_nSymbols; j++)
         {
            if(j==i) continue;
            double w = MathAbs(g_corr[i][j]); // |correlation| plays the role of L_ij exposure
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

      double atr = iATR(g_symbols[i], InpTF, InpATRPeriod, 0);
      double price = SymbolInfoDouble(g_symbols[i], SYMBOL_BID);
      g_barrier[i] = price - InpBarrierATRMult * atr; // "capital-zero" analogue

      // Horizon expressed in bars-as-years is a simplification: we use InpVolLookback
      // bars as one unit of "time" so that T=1 corresponds to the estimation window.
      double T = 1.0;
      g_ownSurv[i] = SurvivalProbability(price, g_barrier[i], g_vol[i], g_drift[i], T);
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
//| Term-structure inversion check for one symbol                      |
//+------------------------------------------------------------------+
bool IsTermStructureInverted(int idx)
{
   double price = SymbolInfoDouble(g_symbols[idx], SYMBOL_BID);

   double Tshort = InpShortHorizonDays / 252.0;
   double Tlong  = InpLongHorizonDays  / 252.0;

   double pShort = SurvivalProbability(price, g_barrier[idx], g_vol[idx], g_drift[idx], Tshort);
   double pLong  = SurvivalProbability(price, g_barrier[idx], g_vol[idx], g_drift[idx], Tlong);

   if(pShort <= 0.0 || pLong <= 0.0) return true; // treat degenerate case as stressed

   double rShort = MathPow(pShort, -1.0/Tshort) - 1.0;
   double rLong  = MathPow(pLong,  -1.0/Tlong ) - 1.0;

   return (rShort > rLong);
}

//+------------------------------------------------------------------+
//| Simple trend core signal (fast/slow MA) -- the "strategy" the      |
//| risk engine is wrapped around. Swap this out freely.               |
//+------------------------------------------------------------------+
int TrendSignal(string sym)
{
   double maFast = iMA(sym, InpTF, InpMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double maSlow = iMA(sym, InpTF, InpMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
   double maFastPrev = iMA(sym, InpTF, InpMAFastPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double maSlowPrev = iMA(sym, InpTF, InpMASlowPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);

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
//| Execute a market order sized and stopped according to distress     |
//+------------------------------------------------------------------+
void ExecuteTrade(string sym, int direction, double distressMult)
{
   double pip = PipSize(sym);
   double lot = NormalizeDouble(InpBaseLot / distressMult, 2);
   if(lot < SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN))
      lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   double stopPips = InpBaseStopPips * distressMult; // widen stop under distress
   double tpPips   = InpBaseTPPips;                  // TP left unscaled (asymmetric by design)

   double price = (direction>0) ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                 : SymbolInfoDouble(sym, SYMBOL_BID);
   double sl = (direction>0) ? price - stopPips*pip : price + stopPips*pip;
   double tp = (direction>0) ? price + tpPips*pip   : price - tpPips*pip;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = sym;
   request.volume    = lot;
   request.type      = (direction>0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price     = price;
   request.sl        = NormalizeDouble(sl, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   request.tp        = NormalizeDouble(tp, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
   request.deviation = 10;
   request.magic     = InpMagic;
   request.comment   = "ContagionEA d="+DoubleToString(distressMult,2);

   OrderSend(request, result);
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

   if(!RefreshNetworkState())
   {
      Print("SystemicContagionEA: initial network state could not be built (insufficient history?).");
      return INIT_FAILED;
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
   datetime curBarTime = iTime(_Symbol, InpTF, 0);
   if(curBarTime == lastBarTime) return; // act once per closed bar
   lastBarTime = curBarTime;

   if(!RefreshNetworkState()) return;

   double mySurv       = g_ownSurv[g_thisSymbolIndex];
   double myNetSurv    = g_netSurv[g_thisSymbolIndex];
   bool   inverted     = IsTermStructureInverted(g_thisSymbolIndex);
   double distressMult = DistressMultiplier(myNetSurv);

   Comment(StringFormat(
      "SystemicContagionEA\n"
      "Symbol: %s\n"
      "Own survival prob:      %.4f\n"
      "Network-adjusted prob:  %.4f\n"
      "Term structure inverted: %s\n"
      "Distress multiplier:    %.2fx\n"
      "Min network threshold:  %.2f",
      _Symbol, mySurv, myNetSurv, (inverted?"YES (stress)":"no"),
      distressMult, InpMinNetworkSurv));

   // --- Risk gate: paper's core message -- don't wait for an actual default ---
   if(myNetSurv < InpMinNetworkSurv)
   {
      Print("SystemicContagionEA: network survival probability ", DoubleToString(myNetSurv,4),
            " below threshold ", InpMinNetworkSurv, " -- skipping new entries this bar.");
      return;
   }
   if(inverted)
   {
      Print("SystemicContagionEA: term structure inverted for ", _Symbol,
            " -- skipping new entries this bar.");
      return;
   }
   if(HasOpenPosition(_Symbol)) return;

   int signal = TrendSignal(_Symbol);
   if(signal != 0)
      ExecuteTrade(_Symbol, signal, distressMult);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}
//+------------------------------------------------------------------+
