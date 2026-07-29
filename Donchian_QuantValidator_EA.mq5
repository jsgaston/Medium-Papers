//+------------------------------------------------------------------+
//|                                Donchian_QuantValidator_EA.mq5    |
//|  Validador estadístico + trading en vivo MULTI-SÍMBOLO de la      |
//|  estrategia Donchian Channel Breakout, con panel visual en el     |
//|  gráfico mostrando el estado de cada símbolo en tiempo real.      |
//|                                                                    |
//|  Al adjuntarlo (OnInit):                                          |
//|   1) Para cada símbolo de InpSymbolsList, corre UNA VEZ el         |
//|      análisis completo: backtest interno, optimización de         |
//|      entry_period, Monte Carlo (permutación de precios) y         |
//|      Walk-Forward Analysis. Exporta un CSV de informe por símbolo.|
//|   2) A partir de ahí, OPERA en cada símbolo con el entry_period    |
//|      que la validación determinó como óptimo (o uno fijo).        |
//|   3) Dibuja un panel en el gráfico con el estado de cada símbolo:  |
//|      periodo usado, profit factor y p-value de la validación,     |
//|      y si en este momento puede o no abrir operaciones (y por qué)|
//+------------------------------------------------------------------+
#property copyright "Javier Santiago"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade         trade;
CPositionInfo  posInfo;

//------------------------------------------------------------------
// INPUTS
//------------------------------------------------------------------
input group "=== Símbolos ==="
input string   InpSymbolsList      = "AUDCAD,AUDCHF,AUDJPY,AUDNZD,AUDUSD,CADCHF,CADJPY,CHFJPY,EURAUD,EURCAD,EURCHF,EURGBP,EURJPY,EURNZD,EURUSD,GBPAUD,GBPCAD,GBPCHF,GBPJPY,GBPNZD,GBPUSD,NZDCAD,NZDCHF,NZDJPY,NZDUSD,USDCAD,USDCHF,USDJPY";        // Lista separada por comas ("EURUSD,GBPUSD,USDJPY"). Vacío = símbolo del gráfico
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;
input int      InpBarsToAnalyze    = 5000;      // Nº de velas históricas a usar por símbolo

input group "=== Estrategia Donchian ==="
input int      InpEntryPeriodMin   = 10;
input int      InpEntryPeriodMax   = 60;
input int      InpEntryPeriodStep  = 5;
input int      InpExitPeriod       = 10;
input bool     InpUseExitChannel   = true;
input int      InpATRPeriod        = 14;
input double   InpSL_ATR_Mult      = 2.0;
input double   InpTP_ATR_Mult      = 4.0;
input double   InpCostPerTrade     = 0.0002;
input int      InpMinTradesOptim   = 5;

input group "=== Monte Carlo ==="
input int      InpMCSimulations    = 200;

input group "=== Walk-Forward ==="
input int      InpWF_TrainBars     = 1000;
input int      InpWF_TestBars      = 250;

input group "=== Informe ==="
input string   InpReportCSVPrefix  = "QuantValidationReport"; // se generará "<prefijo>_<símbolo>.csv"
input int      InpRandomSeed       = 0;

input group "=== Trading en vivo ==="
input bool     InpEnableTrading      = true;
input bool     InpUseOptimizedPeriod = true;
input int      InpLiveEntryPeriod    = 20;
input double   InpRiskPercent        = 1.0;
input bool     InpUseTrailing        = true;
input double   InpTrailing_ATR_Mult  = 2.0;
input int      InpMaxSpreadPoints    = 30;
input double   InpMaxLot             = 5.0;
input ulong    InpMagicNumber        = 202603;
input string   InpTradeComment       = "DonchianQuantValidatorEA";

input group "=== Panel visual ==="
input bool     InpShowPanel        = true;
input int      InpPanelX           = 10;
input int      InpPanelY           = 20;

//------------------------------------------------------------------
// ESTRUCTURAS
//------------------------------------------------------------------
struct BTResult
{
   double profit_factor;
   double total_return;
   double win_rate;
   double max_drawdown;
   double sharpe;
   int    num_trades;
};

struct WFWindow
{
   int    best_entry_period;
   double in_sample_pf;
   double out_sample_pf;
   int    out_sample_trades;
   double out_sample_return;
};

struct SymbolState
{
   string   symbol;
   int      entryPeriod;
   int      atrHandle;
   datetime lastBarTime;
   double   validationPF;
   double   validationPValue;
   int      validationTrades;
   bool     validated;
   string   status;
};

//------------------------------------------------------------------
// GLOBALES
//------------------------------------------------------------------
double g_open[], g_high[], g_low[], g_close[]; // buffer de trabajo (un símbolo a la vez, durante la validación)
int    g_bars = 0;
string g_symbol; // símbolo actualmente cargado en g_open/g_high/g_low/g_close

SymbolState g_states[];
int         g_numSymbols = 0;

#define PANEL_PREFIX "QVP_"

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRandomSeed != 0) MathSrand(InpRandomSeed);
   else                   MathSrand((int)GetTickCount());

   ParseSymbolsList();

   ArrayResize(g_states, g_numSymbols);
   for(int i = 0; i < g_numSymbols; i++)
   {
      g_states[i].entryPeriod      = InpLiveEntryPeriod;
      g_states[i].atrHandle        = INVALID_HANDLE;
      g_states[i].lastBarTime      = 0;
      g_states[i].validationPF     = 0;
      g_states[i].validationPValue = 1.0;
      g_states[i].validationTrades = 0;
      g_states[i].validated        = false;
      g_states[i].status           = "Inicializando...";

      g_symbol = g_states[i].symbol;
      if(LoadHistory())
      {
         int    bestPeriod; double bestPF; double pValue; int numTrades;
         RunFullValidation(g_symbol, bestPeriod, bestPF, pValue, numTrades);

         g_states[i].entryPeriod      = InpUseOptimizedPeriod ? bestPeriod : InpLiveEntryPeriod;
         g_states[i].validationPF     = bestPF;
         g_states[i].validationPValue = pValue;
         g_states[i].validationTrades = numTrades;
         g_states[i].validated        = true;
      }
      else
      {
         Print(g_states[i].symbol, ": histórico insuficiente. Se usará InpLiveEntryPeriod=",
               InpLiveEntryPeriod, " sin validación estadística.");
      }

      if(InpEnableTrading)
      {
         g_states[i].atrHandle = iATR(g_states[i].symbol, InpTimeframe, InpATRPeriod);
         if(g_states[i].atrHandle == INVALID_HANDLE)
            Print("Error creando handle ATR para ", g_states[i].symbol);
      }
   }

   if(InpEnableTrading)
   {
      trade.SetExpertMagicNumber(InpMagicNumber);
      trade.SetDeviationInPoints(20);
      EventSetTimer(1); // permite procesar símbolos que no sean el del gráfico activo
   }

   if(InpShowPanel) CreatePanel();
   UpdatePanel();

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   for(int i = 0; i < g_numSymbols; i++)
      if(g_states[i].atrHandle != INVALID_HANDLE) IndicatorRelease(g_states[i].atrHandle);

   EventKillTimer();
   ObjectsDeleteAll(0, PANEL_PREFIX);
}

//+------------------------------------------------------------------+
//| Separa InpSymbolsList por comas; vacío -> símbolo del gráfico      |
//+------------------------------------------------------------------+
void ParseSymbolsList()
{
   string list = InpSymbolsList;
   StringTrimLeft(list); StringTrimRight(list);

   if(list == "")
   {
      g_numSymbols = 1;
      ArrayResize(g_states, 1);
      g_states[0].symbol = _Symbol;
      return;
   }

   string parts[];
   int n = StringSplit(list, ',', parts);
   ArrayResize(g_states, 0);
   g_numSymbols = 0;

   for(int i = 0; i < n; i++)
   {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s == "") continue;

      if(!SymbolSelect(s, true))
      {
         Print("Símbolo no disponible en Market Watch, se omite: ", s);
         continue;
      }
      g_numSymbols++;
      ArrayResize(g_states, g_numSymbols);
      g_states[g_numSymbols - 1].symbol = s;
   }

   if(g_numSymbols == 0)
   {
      Print("Ningún símbolo válido en InpSymbolsList, se usa el símbolo del gráfico: ", _Symbol);
      g_numSymbols = 1;
      ArrayResize(g_states, 1);
      g_states[0].symbol = _Symbol;
   }
}

//+------------------------------------------------------------------+
//| Carga OHLC de g_symbol en los arrays de trabajo (0=más antiguo)   |
//+------------------------------------------------------------------+
bool LoadHistory()
{
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(g_symbol, InpTimeframe, 0, InpBarsToAnalyze, rates);
   if(copied < InpWF_TrainBars + InpWF_TestBars + InpEntryPeriodMax + 50)
   {
      Print(g_symbol, ": histórico insuficiente (", copied, " velas copiadas)");
      return false;
   }

   g_bars = copied;
   ArrayResize(g_open, g_bars); ArrayResize(g_high, g_bars);
   ArrayResize(g_low, g_bars);  ArrayResize(g_close, g_bars);

   for(int i = 0; i < g_bars; i++)
   {
      g_open[i]  = rates[i].open;
      g_high[i]  = rates[i].high;
      g_low[i]   = rates[i].low;
      g_close[i] = rates[i].close;
   }
   Print(g_symbol, ": histórico cargado (", g_bars, " velas, ", EnumToString(InpTimeframe), ")");
   return true;
}

//+------------------------------------------------------------------+
//| Rolling max/min sobre 'period' barras ANTERIORES a idx (excl.)    |
//+------------------------------------------------------------------+
double RollingMax(const double &arr[], int idx, int period)
{
   double m = -DBL_MAX; bool found = false;
   for(int k = idx - period; k < idx; k++)
   {
      if(k < 0) continue;
      found = true;
      if(arr[k] > m) m = arr[k];
   }
   return (found ? m : DBL_MAX);
}

double RollingMin(const double &arr[], int idx, int period)
{
   double m = DBL_MAX; bool found = false;
   for(int k = idx - period; k < idx; k++)
   {
      if(k < 0) continue;
      found = true;
      if(arr[k] < m) m = arr[k];
   }
   return (found ? m : -DBL_MAX);
}

//+------------------------------------------------------------------+
void ComputeATR(const double &high[], const double &low[], const double &close[], int period, double &atrOut[])
{
   int n = ArraySize(close);
   ArrayResize(atrOut, n);
   ArrayInitialize(atrOut, 0.0);

   double tr[];
   ArrayResize(tr, n);
   tr[0] = high[0] - low[0];
   for(int i = 1; i < n; i++)
   {
      double hl = high[i] - low[i];
      double hc = MathAbs(high[i] - close[i-1]);
      double lc = MathAbs(low[i]  - close[i-1]);
      tr[i] = MathMax(hl, MathMax(hc, lc));
   }
   for(int i = period - 1; i < n; i++)
   {
      double sum = 0;
      for(int k = i - period + 1; k <= i; k++) sum += tr[k];
      atrOut[i] = sum / period;
   }
}

void AppendReturn(double &arr[], double value)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = value;
}

void ComputeStatsFromReturns(const double &returns[], BTResult &result)
{
   int n = ArraySize(returns);
   result.num_trades = n;
   if(n == 0)
   {
      result.profit_factor = 0; result.total_return = 0; result.win_rate = 0;
      result.max_drawdown = 0; result.sharpe = 0;
      return;
   }

   double gains = 0, losses = 0, sumRet = 0, wins = 0;
   double equity = 1.0, peak = 1.0, maxDD = 0;

   for(int i = 0; i < n; i++)
   {
      double r = returns[i];
      sumRet += r;
      if(r > 0) { gains += r; wins += 1; } else { losses += -r; }
      equity *= (1.0 + r);
      if(equity > peak) peak = equity;
      double dd = (equity - peak) / peak;
      if(dd < maxDD) maxDD = dd;
   }

   result.profit_factor = (losses > 0) ? (gains / losses) : (gains > 0 ? DBL_MAX : 0.0);
   result.win_rate = wins / n;
   result.total_return = equity - 1.0;
   result.max_drawdown = maxDD;

   double mean = sumRet / n, variance = 0;
   for(int i = 0; i < n; i++) variance += MathPow(returns[i] - mean, 2);
   variance /= n;
   double stdDev = MathSqrt(variance);
   result.sharpe = (stdDev > 0) ? (mean / stdDev) * MathSqrt((double)n) : 0.0;
}

//+------------------------------------------------------------------+
//| Backtest interno (offline, sobre arrays) de la estrategia Donchian |
//+------------------------------------------------------------------+
void RunBacktest(const double &open[], const double &high[], const double &low[], const double &close[],
                  int startIdx, int endIdx, int entryPeriod, int exitPeriod, int atrPeriod,
                  double slMult, double tpMult, double costPerTrade,
                  double &returnsOut[], BTResult &result)
{
   ArrayResize(returnsOut, 0);
   double atr[];
   ComputeATR(high, low, close, atrPeriod, atr);

   int position = 0;
   double entryPrice = 0, sl = 0, tp = 0;
   bool useTp = (tpMult > 0);
   int firstValid = MathMax(startIdx, MathMax(entryPeriod, atrPeriod) + 1);

   for(int i = firstValid; i < endIdx; i++)
   {
      double price = close[i];
      double atrVal = atr[i];

      if(position == 0)
      {
         if(atrVal <= 0) continue;
         double upper = RollingMax(high, i, entryPeriod);
         double lower = RollingMin(low, i, entryPeriod);

         if(price > upper)
         {
            position = 1; entryPrice = price;
            sl = entryPrice - atrVal * slMult;
            tp = useTp ? entryPrice + atrVal * tpMult : 0;
         }
         else if(price < lower)
         {
            position = -1; entryPrice = price;
            sl = entryPrice + atrVal * slMult;
            tp = useTp ? entryPrice - atrVal * tpMult : 0;
         }
      }
      else if(position == 1)
      {
         double exitLower = RollingMin(low, i, exitPeriod);
         bool exitNow = (price <= sl) || (useTp && price >= tp) || (price <= exitLower);
         if(exitNow)
         {
            AppendReturn(returnsOut, (price - entryPrice) / entryPrice - costPerTrade);
            position = 0;
         }
      }
      else if(position == -1)
      {
         double exitUpper = RollingMax(high, i, exitPeriod);
         bool exitNow = (price >= sl) || (useTp && price <= tp) || (price >= exitUpper);
         if(exitNow)
         {
            AppendReturn(returnsOut, (entryPrice - price) / entryPrice - costPerTrade);
            position = 0;
         }
      }
   }
   ComputeStatsFromReturns(returnsOut, result);
}

int OptimizeEntryPeriod(int startIdx, int endIdx, double &bestPF)
{
   int bestPeriod = InpEntryPeriodMin;
   bestPF = -DBL_MAX;
   for(int p = InpEntryPeriodMin; p <= InpEntryPeriodMax; p += InpEntryPeriodStep)
   {
      double retArr[]; BTResult res;
      RunBacktest(g_open, g_high, g_low, g_close, startIdx, endIdx, p, InpExitPeriod,
                  InpATRPeriod, InpSL_ATR_Mult, InpTP_ATR_Mult, InpCostPerTrade, retArr, res);
      if(res.num_trades >= InpMinTradesOptim && res.profit_factor > bestPF)
      {
         bestPF = res.profit_factor;
         bestPeriod = p;
      }
   }
   return bestPeriod;
}

void ShuffleIndices(int &idxArr[])
{
   int n = ArraySize(idxArr);
   for(int i = n - 1; i > 0; i--)
   {
      int j = (int)((MathRand() / 32768.0) * (i + 1));
      if(j > i) j = i;
      int tmp = idxArr[i]; idxArr[i] = idxArr[j]; idxArr[j] = tmp;
   }
}

void BuildShuffledSeries(int startIdx, int endIdx, double &synthOpen[], double &synthHigh[],
                          double &synthLow[], double &synthClose[])
{
   int n = endIdx - startIdx;
   double oRatio[], hRatio[], lRatio[], cRatio[];
   ArrayResize(oRatio, n); ArrayResize(hRatio, n); ArrayResize(lRatio, n); ArrayResize(cRatio, n);

   for(int k = 0; k < n; k++)
   {
      int i = startIdx + k;
      double prevClose = g_close[i - 1];
      oRatio[k] = g_open[i] / prevClose; hRatio[k] = g_high[i] / prevClose;
      lRatio[k] = g_low[i] / prevClose;  cRatio[k] = g_close[i] / prevClose;
   }

   int order[]; ArrayResize(order, n);
   for(int k = 0; k < n; k++) order[k] = k;
   ShuffleIndices(order);

   ArrayResize(synthOpen, n); ArrayResize(synthHigh, n);
   ArrayResize(synthLow, n);  ArrayResize(synthClose, n);

   double prevC = g_close[startIdx - 1];
   for(int k = 0; k < n; k++)
   {
      int src = order[k];
      double c = prevC * cRatio[src], o = prevC * oRatio[src];
      double h = prevC * hRatio[src], l = prevC * lRatio[src];
      h = MathMax(h, MathMax(o, c));
      l = MathMin(l, MathMin(o, c));
      synthOpen[k] = o; synthHigh[k] = h; synthLow[k] = l; synthClose[k] = c;
      prevC = c;
   }
}

void RunMonteCarloTest(int startIdx, int endIdx, int entryPeriod,
                        double &observedStat, double &pValue, double &simMean, double &simStd)
{
   double realReturns[]; BTResult realRes;
   RunBacktest(g_open, g_high, g_low, g_close, startIdx, endIdx, entryPeriod, InpExitPeriod,
               InpATRPeriod, InpSL_ATR_Mult, InpTP_ATR_Mult, InpCostPerTrade, realReturns, realRes);
   observedStat = realRes.profit_factor;

   int shuffleStart = MathMax(startIdx, 1);
   double sims[]; ArrayResize(sims, InpMCSimulations);

   for(int s = 0; s < InpMCSimulations; s++)
   {
      double sOpen[], sHigh[], sLow[], sClose[];
      BuildShuffledSeries(shuffleStart, endIdx, sOpen, sHigh, sLow, sClose);
      double simReturns[]; BTResult simRes;
      RunBacktest(sOpen, sHigh, sLow, sClose, 0, ArraySize(sClose), entryPeriod, InpExitPeriod,
                  InpATRPeriod, InpSL_ATR_Mult, InpTP_ATR_Mult, InpCostPerTrade, simReturns, simRes);
      sims[s] = simRes.profit_factor;
   }

   int countGE = 0; double sum = 0, sumSq = 0; int validCount = 0;
   for(int s = 0; s < InpMCSimulations; s++)
   {
      if(sims[s] >= observedStat) countGE++;
      if(sims[s] < DBL_MAX) { sum += sims[s]; sumSq += sims[s]*sims[s]; validCount++; }
   }
   pValue  = (double)(countGE + 1) / (double)(InpMCSimulations + 1);
   simMean = (validCount > 0) ? sum / validCount : 0;
   simStd  = (validCount > 0) ? MathSqrt(MathMax(0.0, sumSq/validCount - simMean*simMean)) : 0;
}

int RunWalkForward(WFWindow &windows[])
{
   ArrayResize(windows, 0);
   int start = 0, count = 0;

   while(start + InpWF_TrainBars + InpWF_TestBars <= g_bars)
   {
      int trainStart = start, trainEnd = start + InpWF_TrainBars;
      int testStart  = trainEnd, testEnd = trainEnd + InpWF_TestBars;

      double bestPF;
      int bestPeriod = OptimizeEntryPeriod(trainStart, trainEnd, bestPF);

      double testReturns[]; BTResult testRes;
      RunBacktest(g_open, g_high, g_low, g_close, testStart, testEnd, bestPeriod, InpExitPeriod,
                  InpATRPeriod, InpSL_ATR_Mult, InpTP_ATR_Mult, InpCostPerTrade, testReturns, testRes);

      if(testRes.num_trades >= 1 && bestPF > -DBL_MAX)
      {
         WFWindow w;
         w.best_entry_period = bestPeriod;
         w.in_sample_pf = bestPF;
         w.out_sample_pf = testRes.profit_factor;
         w.out_sample_trades = testRes.num_trades;
         w.out_sample_return = testRes.total_return;
         count++;
         ArrayResize(windows, count);
         windows[count - 1] = w;
      }
      start += InpWF_TestBars;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Orquesta la validación completa de UN símbolo (g_open/... ya      |
//| deben estar cargados con LoadHistory()) y devuelve los resultados |
//+------------------------------------------------------------------+
void RunFullValidation(string symbolName, int &outBestPeriod, double &outPF, double &outPValue, int &outNumTrades)
{
   Print("==================== ", symbolName, " ====================");
   double bestPF;
   int bestPeriod = OptimizeEntryPeriod(0, g_bars, bestPF);
   Print(symbolName, ": mejor entry_period=", bestPeriod, " PF=", DoubleToString(bestPF, 2));

   double baseReturns[]; BTResult baseRes;
   RunBacktest(g_open, g_high, g_low, g_close, 0, g_bars, bestPeriod, InpExitPeriod, InpATRPeriod,
               InpSL_ATR_Mult, InpTP_ATR_Mult, InpCostPerTrade, baseReturns, baseRes);
   Print(symbolName, ": operaciones=", baseRes.num_trades, " win_rate=",
         DoubleToString(baseRes.win_rate*100,1), "% maxDD=", DoubleToString(baseRes.max_drawdown*100,1), "%");

   double observedStat, pValue, simMean, simStd;
   RunMonteCarloTest(0, g_bars, bestPeriod, observedStat, pValue, simMean, simStd);
   Print(symbolName, ": Monte Carlo PF=", DoubleToString(observedStat,2), " p-value=", DoubleToString(pValue,4),
         (pValue < 0.05 ? "  [SIGNIFICATIVO]" : "  [NO significativo]"));

   WFWindow windows[];
   int nWindows = RunWalkForward(windows);
   double sumOutPF = 0; int validPF = 0, profitableWindows = 0; double compEquity = 1.0;
   for(int i = 0; i < nWindows; i++)
   {
      if(windows[i].out_sample_pf < DBL_MAX) { sumOutPF += windows[i].out_sample_pf; validPF++; }
      if(windows[i].out_sample_return > 0) profitableWindows++;
      compEquity *= (1.0 + windows[i].out_sample_return);
   }
   if(nWindows > 0)
      Print(symbolName, ": Walk-Forward ", nWindows, " ventanas | ",
            DoubleToString(100.0*profitableWindows/nWindows,1), "% rentables | retorno compuesto ",
            DoubleToString((compEquity-1)*100,2), "%");
   else
      Print(symbolName, ": Walk-Forward sin ventanas suficientes");

   WriteReportCSV(symbolName, bestPeriod, baseRes, observedStat, pValue, simMean, simStd, windows, nWindows);

   outBestPeriod = bestPeriod;
   outPF = observedStat;
   outPValue = pValue;
   outNumTrades = baseRes.num_trades;
}

void WriteReportCSV(string symbolName, int bestPeriod, const BTResult &baseRes, double observedStat,
                     double pValue, double simMean, double simStd, const WFWindow &windows[], int nWindows)
{
   string fileName = InpReportCSVPrefix + "_" + symbolName + ".csv";
   int h = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI, ';');
   if(h == INVALID_HANDLE) { Print("No se pudo crear CSV para ", symbolName, ". Error=", GetLastError()); return; }

   FileWrite(h, "symbol", symbolName);
   FileWrite(h, "best_entry_period", bestPeriod);
   FileWrite(h, "base_profit_factor", DoubleToString(baseRes.profit_factor, 4));
   FileWrite(h, "base_num_trades", baseRes.num_trades);
   FileWrite(h, "base_win_rate", DoubleToString(baseRes.win_rate, 4));
   FileWrite(h, "base_max_drawdown", DoubleToString(baseRes.max_drawdown, 4));
   FileWrite(h, "monte_carlo_observed_pf", DoubleToString(observedStat, 4));
   FileWrite(h, "monte_carlo_p_value", DoubleToString(pValue, 4));
   FileWrite(h, "");
   FileWrite(h, "window","entry_period","in_sample_pf","out_sample_pf","out_sample_trades","out_sample_return");
   for(int i = 0; i < nWindows; i++)
      FileWrite(h, i+1, windows[i].best_entry_period, DoubleToString(windows[i].in_sample_pf,4),
                DoubleToString(windows[i].out_sample_pf,4), windows[i].out_sample_trades,
                DoubleToString(windows[i].out_sample_return,4));
   FileClose(h);
}

//+------------------------------------------------------------------+
//|                     TRADING EN VIVO (multi-símbolo)               |
//+------------------------------------------------------------------+
double GetATRForHandle(int handle)
{
   if(handle == INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, 1, 1, buf) <= 0) return 0.0;
   return buf[0];
}

bool GetDonchianLive(string sym, int period, int shiftStart, double &upper, double &lower)
{
   int highestIdx = iHighest(sym, InpTimeframe, MODE_HIGH, period, shiftStart);
   int lowestIdx  = iLowest(sym, InpTimeframe, MODE_LOW, period, shiftStart);
   if(highestIdx < 0 || lowestIdx < 0) return false;
   upper = iHigh(sym, InpTimeframe, highestIdx);
   lower = iLow(sym, InpTimeframe, lowestIdx);
   return true;
}

int GetSpreadPoints(string sym)
{
   long spread = 0;
   SymbolInfoInteger(sym, SYMBOL_SPREAD, spread);
   return (int)spread;
}

double CalcLotSize(string sym, double slDistancePrice)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0 || slDistancePrice <= 0)
      return SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   double lots = riskMoney / lossPerLot;

   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double lotMax  = MathMin(InpMaxLot, SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX));

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lotMin, MathMin(lotMax, lots));
   return NormalizeDouble(lots, 2);
}

int CountOpenPositions(string sym)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == sym && posInfo.Magic() == InpMagicNumber)
         count++;
   return count;
}

void OpenLiveTrade(string sym, bool isBuy, double atrValue)
{
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick)) return;
   double price = isBuy ? tick.ask : tick.bid;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double slDist = atrValue * InpSL_ATR_Mult;
   double tpDist = (InpTP_ATR_Mult > 0) ? atrValue * InpTP_ATR_Mult : 0;
   double sl = NormalizeDouble(isBuy ? price - slDist : price + slDist, digits);
   double tp = (tpDist > 0) ? NormalizeDouble(isBuy ? price + tpDist : price - tpDist, digits) : 0;

   double lots = CalcLotSize(sym, slDist);
   if(lots <= 0) return;

   trade.SetTypeFillingBySymbol(sym);
   bool ok = isBuy ? trade.Buy(lots, sym, price, sl, tp, InpTradeComment)
                   : trade.Sell(lots, sym, price, sl, tp, InpTradeComment);
   if(!ok)
      Print(sym, ": error al abrir ", (isBuy ? "BUY" : "SELL"), ". Retcode=", trade.ResultRetcode(),
            " - ", trade.ResultRetcodeDescription());
}

void ManageLivePositions(string sym, double atrValue)
{
   double exitUpper, exitLower;
   bool haveExitChannel = InpUseExitChannel && GetDonchianLive(sym, InpExitPeriod, 1, exitUpper, exitLower);

   MqlTick tick;
   if(!SymbolInfoTick(sym, tick)) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != sym || posInfo.Magic() != InpMagicNumber) continue;

      ulong ticket = posInfo.Ticket();
      bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
      double curSL = posInfo.StopLoss();
      double curPrice = isBuy ? tick.bid : tick.ask;

      if(haveExitChannel)
      {
         if(isBuy && curPrice <= exitLower) { trade.PositionClose(ticket); continue; }
         if(!isBuy && curPrice >= exitUpper) { trade.PositionClose(ticket); continue; }
      }

      if(InpUseTrailing && atrValue > 0)
      {
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         double pointSize = SymbolInfoDouble(sym, SYMBOL_POINT);
         long stopsLevelPoints = 0;
         SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL, stopsLevelPoints);
         double minDistance = MathMax(stopsLevelPoints, 1) * pointSize;

         double trailDist = atrValue * InpTrailing_ATR_Mult;

         if(isBuy)
         {
            double newSL = NormalizeDouble(curPrice - trailDist, digits);
            bool farEnoughFromPrice = (curPrice - newSL) >= minDistance;
            bool actuallyMoves     = (curSL == 0) || (newSL - curSL) > pointSize; // evita "sin cambios"
            if(farEnoughFromPrice && actuallyMoves && newSL < curPrice)
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
         }
         else
         {
            double newSL = NormalizeDouble(curPrice + trailDist, digits);
            bool farEnoughFromPrice = (newSL - curPrice) >= minDistance;
            bool actuallyMoves     = (curSL == 0) || (curSL - newSL) > pointSize;
            if(farEnoughFromPrice && actuallyMoves && newSL > curPrice)
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Procesa un símbolo: gestiona posiciones abiertas siempre, y busca |
//| nueva entrada solo al cerrar una vela nueva. Actualiza el status  |
//| textual usado por el panel.                                       |
//+------------------------------------------------------------------+
void ProcessSymbolTick(int idx)
{
   string sym = g_states[idx].symbol;

   if(!InpEnableTrading) { g_states[idx].status = "Trading desactivado"; return; }
   if(g_states[idx].atrHandle == INVALID_HANDLE) { g_states[idx].status = "Sin handle ATR"; return; }

   double atrValue = GetATRForHandle(g_states[idx].atrHandle);
   int spread = GetSpreadPoints(sym);
   int openPos = CountOpenPositions(sym);

   datetime t = iTime(sym, InpTimeframe, 0);
   bool isNewBar = (t != g_states[idx].lastBarTime && t != 0);
   if(isNewBar) g_states[idx].lastBarTime = t;

   if(openPos > 0)
   {
      ManageLivePositions(sym, atrValue);
      g_states[idx].status = "En posición";
      return;
   }

   if(atrValue <= 0) { g_states[idx].status = "Esperando datos ATR"; return; }
   if(spread > InpMaxSpreadPoints) { g_states[idx].status = "Bloqueado: spread " + IntegerToString(spread) + "p"; return; }

   if(!isNewBar) { g_states[idx].status = "Esperando cierre de vela"; return; }

   double upper, lower;
   if(!GetDonchianLive(sym, g_states[idx].entryPeriod, 1, upper, lower))
   {
      g_states[idx].status = "Esperando datos de canal";
      return;
   }

   double closeNow = iClose(sym, InpTimeframe, 0);
   if(closeNow > upper)
   {
      OpenLiveTrade(sym, true, atrValue);
      g_states[idx].status = "Señal BUY ejecutada";
   }
   else if(closeNow < lower)
   {
      OpenLiveTrade(sym, false, atrValue);
      g_states[idx].status = "Señal SELL ejecutada";
   }
   else
   {
      g_states[idx].status = "Esperando ruptura";
   }
}

void ProcessAllSymbols()
{
   for(int i = 0; i < g_numSymbols; i++)
      ProcessSymbolTick(i);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ProcessAllSymbols();
   if(InpShowPanel) UpdatePanel();
}

void OnTimer()
{
   ProcessAllSymbols();
   if(InpShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//|                          PANEL VISUAL                              |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int rowHeight = 18;
   int width = 480;
   int height = 40 + rowHeight * g_numSymbols;

   string bg = PANEL_PREFIX + "BG";
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,20,20');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);

   CreateLabel(PANEL_PREFIX + "Title", InpPanelX + 8, InpPanelY + 6,
               "Donchian QuantValidator — estado por símbolo", clrWhite);

   for(int i = 0; i < g_numSymbols; i++)
   {
      CreateLabel(PANEL_PREFIX + "Row" + IntegerToString(i), InpPanelX + 8, InpPanelY + 26 + i * rowHeight,
                  g_states[i].symbol + ": inicializando...", clrSilver);
   }
}

void CreateLabel(string name, int x, int y, string text, color clr)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void UpdatePanel()
{
   if(!InpShowPanel) return;

   for(int i = 0; i < g_numSymbols; i++)
   {
      string name = PANEL_PREFIX + "Row" + IntegerToString(i);
      string valLine;
      if(g_states[i].validated)
         valLine = StringFormat("period=%d  PF=%.2f  p=%.3f%s",
                                 g_states[i].entryPeriod, g_states[i].validationPF, g_states[i].validationPValue,
                                 (g_states[i].validationPValue < 0.05 ? " [OK]" : " [no-sig]"));
      else
         valLine = StringFormat("period=%d  (sin validar)", g_states[i].entryPeriod);

      string text = StringFormat("%-8s %-30s | %s", g_states[i].symbol, valLine, g_states[i].status);

      color clr = clrSilver;
      if(StringFind(g_states[i].status, "posición") >= 0)      clr = clrDeepSkyBlue;
      else if(StringFind(g_states[i].status, "ejecutada") >= 0) clr = clrLimeGreen;
      else if(StringFind(g_states[i].status, "Bloqueado") >= 0) clr = clrOrange;
      else if(StringFind(g_states[i].status, "desactivado") >= 0) clr = clrGray;

      if(ObjectFind(0, name) < 0) CreateLabel(name, InpPanelX + 8, InpPanelY + 26 + i * 18, text, clr);
      else
      {
         ObjectSetString(0, name, OBJPROP_TEXT, text);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      }
   }
   ChartRedraw(0);
}
//+------------------------------------------------------------------+