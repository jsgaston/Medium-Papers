//+------------------------------------------------------------------+
//|                                     XAUUSD_RegimeSignal_EA.mq5   |
//|   EA autonomo basado en el informe estadistico de una senal      |
//|   copiada (312 ops, XAUUSD, WR 73.08%, PF 2.46).                 |
//|                                                                    |
//|   IMPORTANTE - LEER ANTES DE USAR EN REAL:                        |
//|   El informe origen es un analisis RETROSPECTIVO de operaciones   |
//|   ya cerradas de una senal de copia. El "score" compuesto de      |
//|   calidad de entrada del informe NO discrimina bien (las          |
//|   operaciones con score alto tuvieron PEOR resultado que las de   |
//|   score bajo: 69.4% WR vs 78.5% WR). Por eso este EA NO usa un    |
//|   score ponderado como filtro de entrada. En su lugar usa filtros |
//|   individuales con mayor soporte estadistico:                     |
//|     - Simbolo: XAUUSD unicamente                                  |
//|     - Regimen de mercado (ADX + pendiente de MA)                  |
//|     - Volatilidad (ATR) cercana al rango observado en el informe  |
//|     - Franja horaria de mayor actividad (16-18 hora servidor)     |
//|     - Patrones de vela (Pin Bar / Doji) como confirmacion BLANDA  |
//|       (baja confianza en el informe: 42% y menos), no como filtro |
//|       obligatorio salvo que el usuario lo active explicitamente.  |
//|                                                                    |
//|   Los umbrales por defecto son los inferidos del informe, pero    |
//|   DEBEN validarse con backtest/forward test antes de usar en real.|
//+------------------------------------------------------------------+
#property copyright "Javier Santiago Gaston de Iriarte Cabrera"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//====================================================================
// INPUTS
//====================================================================

input group "=== General ==="
input ulong    InpMagic              = 20260810;    // Numero magico
input string   InpSymbolFilter       = "XAUUSD";    // Simbolo permitido (vacio = cualquiera)
input double   InpFixedLot           = 0.01;        // Lote fijo (informe: vol. promedio 0.01, sin martingala)
input bool     InpVerboseLog         = true;         // Logging verboso de diagnostico
input bool     InpDryRunNoTrading    = false;        // Modo diagnostico: NO abre operaciones, solo loguea valores reales (usar primero para calibrar InpVolTarget en M1)

input group "=== Timeframe ==="
// Este EA esta pensado para ejecutarse en el grafico M1 (la senal original opera en M1).
// El regimen de mercado (ADX + pendiente MA) se calcula en un timeframe superior configurable
// para evitar el ruido tipico de M1 al clasificar tendencia/rango.
input ENUM_TIMEFRAMES InpRegimeTF    = PERIOD_M15;   // Timeframe para clasificar regimen (ADX/MA), M1 seria demasiado ruidoso

input group "=== Gestion de riesgo ==="
input bool     InpUseATR_SLTP        = true;         // Usar ATR para SL/TP (si no, usa puntos fijos)
input double   InpSL_ATR_Mult        = 1.5;          // Multiplicador ATR para Stop Loss
input double   InpTP_ATR_Mult        = 2.5;          // Multiplicador ATR para Take Profit (RR ~1:1.66)
input int      InpSL_Points          = 3000;         // SL en puntos si no se usa ATR
input int      InpTP_Points          = 5000;         // TP en puntos si no se usa ATR
input bool     InpUseTrailing        = true;         // Activar trailing stop
input double   InpTrailStart_ATR     = 1.0;          // Empieza a mover SL cuando beneficio > X * ATR
input double   InpTrailStep_ATR      = 0.5;          // Distancia de trailing en X * ATR
input int      InpMaxOpenPositions   = 1;            // Maximo de posiciones simultaneas (magic+symbol)

input group "=== Filtro de Regimen de Mercado ==="
input bool     InpAllowRanging       = true;         // Permitir regimen Ranging (37.4% ops, exp 1.86, WR 65.7%)
input bool     InpAllowWeakTrend     = true;         // Permitir Weak Trend (19.6% ops, exp 2.59, WR 82.9%)
input bool     InpAllowTrending      = true;         // Permitir Trending (7.8% ops, exp 3.14, WR 92.9%)
input bool     InpAllowStrongUptrend = true;         // Permitir Strong Uptrend (14.0% ops, exp 17.50, WR 68.0%)
input bool     InpAllowStrongDowntrend=true;         // Permitir Strong Downtrend (21.2% ops, exp 10.17, WR 81.6%)
input int      InpADX_Period         = 14;           // Periodo ADX
input int      InpTrendMA_Period     = 50;           // Periodo MA para pendiente de tendencia
input double   InpADX_TrendingLevel  = 20.0;         // ADX minimo para considerar "trending"
input double   InpADX_StrongLevel    = 35.0;         // ADX minimo para considerar tendencia "fuerte"

input group "=== Filtro de Volatilidad (ATR) ==="
input bool     InpUseVolatilityFilter= true;          // Activar filtro de volatilidad
input int      InpATR_Period         = 14;            // Periodo ATR
input double   InpVolTarget          = 2.36792;       // Volatilidad optima inferida del informe
input double   InpVolTolerance       = 2.08966;       // Tolerancia +/- (rango informe /2)

input group "=== Filtro Horario ==="
input bool     InpUseTimeFilter      = true;          // Activar filtro horario (hora de servidor)
input int      InpStartHour          = 15;            // Hora inicio (buffer alrededor de pico 16-18)
input int      InpEndHour            = 19;            // Hora fin (exclusiva)

input group "=== Confirmacion de patrones de vela (blanda, opcional) ==="
input bool     InpRequirePinBarBuy   = false;         // Exigir Pin Bar alcista para COMPRAS (baja confianza: 42%)
input bool     InpRequireTrendForSell= true;          // Exigir tendencia bajista < umbral para VENTAS
input double   InpSellTrendThreshold = -0.18;         // % umbral tendencia bajista (informe: media -0.30%)
input int      InpTrendLookback      = 20;            // Barras para calcular % de tendencia

input group "=== Indicadores auxiliares (confirmacion, no bloqueantes) ==="
input int      InpRSI_Period         = 14;
input int      InpMACD_Fast          = 12;
input int      InpMACD_Slow          = 26;
input int      InpMACD_Signal        = 9;

input group "=== Reporting estadistico ==="
input int      InpStatsReportEveryNBars = 50;         // Imprime resumen de stats cada N barras nuevas

//====================================================================
// GLOBALES
//====================================================================
CTrade         trade;
CPositionInfo  posInfo;

int hATR, hADX, hRSI, hMACD, hMA_trend;
datetime lastBarTime = 0;
int barCounter = 0;

// Estadisticas en vivo (desde que arranca el EA)
int    statTotalTrades   = 0;
int    statWins          = 0;
int    statLosses        = 0;
double statGrossProfit   = 0.0;
double statGrossLoss     = 0.0;
double statSumProfitWins = 0.0;
double statSumLossLosses = 0.0;

enum ENUM_REGIME
  {
   REGIME_RANGING,
   REGIME_WEAK_TREND,
   REGIME_TRENDING,
   REGIME_STRONG_UPTREND,
   REGIME_STRONG_DOWNTREND
  };

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSymbolFilter != "" && _Symbol != InpSymbolFilter)
     {
      Print("[XAUUSD_RegimeSignal_EA] AVISO: este EA fue calibrado para ", InpSymbolFilter,
            " y esta corriendo en ", _Symbol, ". Los umbrales por defecto pueden no ser validos.");
     }

   hATR = iATR(_Symbol, PERIOD_CURRENT, InpATR_Period);
   hADX = iADX(_Symbol, InpRegimeTF, InpADX_Period);
   hRSI = iRSI(_Symbol, PERIOD_CURRENT, InpRSI_Period, PRICE_CLOSE);
   hMACD = iMACD(_Symbol, PERIOD_CURRENT, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   hMA_trend = iMA(_Symbol, InpRegimeTF, InpTrendMA_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(PERIOD_CURRENT == PERIOD_M1 || _Period == PERIOD_M1)
      Print("[XAUUSD_RegimeSignal_EA] Ejecutando en M1 (correcto para esta senal). Regimen se calcula en ",
            EnumToString(InpRegimeTF), " para evitar ruido.");
   else
      Print("[XAUUSD_RegimeSignal_EA] AVISO: este EA fue calibrado para el grafico M1 (la senal original opera ahi). ",
            "Estas en ", EnumToString((ENUM_TIMEFRAMES)_Period), ". El ATR/hora se miden en el timeframe del grafico.");

   if(hATR == INVALID_HANDLE || hADX == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
      hMACD == INVALID_HANDLE || hMA_trend == INVALID_HANDLE)
     {
      Print("[XAUUSD_RegimeSignal_EA] ERROR: fallo al crear handles de indicadores.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   Print("[XAUUSD_RegimeSignal_EA] Inicializado. Recordatorio: umbrales inferidos de un informe con ",
         "confianza baja-media en las reglas de entrada. Validar con backtest antes de usar en real.");

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   PrintStatsSummary("FINAL (OnDeinit)");
   IndicatorRelease(hATR);
   IndicatorRelease(hADX);
   IndicatorRelease(hRSI);
   IndicatorRelease(hMACD);
   IndicatorRelease(hMA_trend);
  }

//+------------------------------------------------------------------+
//| Detecta si hay una barra nueva                                    |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime)
     {
      lastBarTime = t;
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Clasifica el regimen de mercado actual                            |
//+------------------------------------------------------------------+
ENUM_REGIME ClassifyRegime(double adxMain, double maSlopePct)
  {
   bool trendingByADX = (adxMain >= InpADX_TrendingLevel);
   bool strongByADX    = (adxMain >= InpADX_StrongLevel);

   if(!trendingByADX)
      return REGIME_RANGING;

   if(strongByADX)
     {
      if(maSlopePct > 0)
         return REGIME_STRONG_UPTREND;
      else
         return REGIME_STRONG_DOWNTREND;
     }

   // Trending pero no "fuerte": distinguir Weak Trend vs Trending por magnitud de ADX
   if(adxMain >= (InpADX_TrendingLevel + InpADX_StrongLevel) / 2.0)
      return REGIME_TRENDING;

   return REGIME_WEAK_TREND;
  }

//+------------------------------------------------------------------+
//| Devuelve true si el regimen esta permitido por inputs             |
//+------------------------------------------------------------------+
bool RegimeAllowed(ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_RANGING:          return InpAllowRanging;
      case REGIME_WEAK_TREND:       return InpAllowWeakTrend;
      case REGIME_TRENDING:         return InpAllowTrending;
      case REGIME_STRONG_UPTREND:   return InpAllowStrongUptrend;
      case REGIME_STRONG_DOWNTREND: return InpAllowStrongDowntrend;
     }
   return false;
  }

string RegimeToString(ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_RANGING:          return "Ranging";
      case REGIME_WEAK_TREND:       return "Weak Trend";
      case REGIME_TRENDING:         return "Trending";
      case REGIME_STRONG_UPTREND:   return "Strong Uptrend";
      case REGIME_STRONG_DOWNTREND: return "Strong Downtrend";
     }
   return "Unknown";
  }

//+------------------------------------------------------------------+
//| Chequeo filtro horario (hora de servidor)                         |
//+------------------------------------------------------------------+
bool TimeFilterOK()
  {
   if(!InpUseTimeFilter)
      return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpStartHour <= InpEndHour)
      return (dt.hour >= InpStartHour && dt.hour < InpEndHour);
   else
      // rango que cruza medianoche
      return (dt.hour >= InpStartHour || dt.hour < InpEndHour);
  }

//+------------------------------------------------------------------+
//| Chequeo filtro de volatilidad                                     |
//+------------------------------------------------------------------+
bool VolatilityFilterOK(double atrValue)
  {
   if(!InpUseVolatilityFilter)
      return true;
   double lo = InpVolTarget - InpVolTolerance;
   double hi = InpVolTarget + InpVolTolerance;
   if(lo < 0) lo = 0;
   return (atrValue >= lo && atrValue <= hi);
  }

//+------------------------------------------------------------------+
//| Calcula el % de tendencia sobre N barras                          |
//+------------------------------------------------------------------+
double CalcTrendPct(int lookback)
  {
   // Se calcula en InpRegimeTF (no en M1) para que el % de tendencia sea representativo
   // y no puro ruido de scalping.
   double closeNow  = iClose(_Symbol, InpRegimeTF, 0);
   double closePast = iClose(_Symbol, InpRegimeTF, lookback);
   if(closePast == 0)
      return 0.0;
   return (closeNow - closePast) / closePast * 100.0;
  }

//+------------------------------------------------------------------+
//| Deteccion simple de Pin Bar (mecha larga en un lado, cuerpo peq.)  |
//| bullish = true busca Pin Bar alcista (mecha inferior larga)        |
//+------------------------------------------------------------------+
bool IsPinBar(int shift, bool bullish)
  {
   double open  = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);
   double high  = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double low   = iLow(_Symbol, PERIOD_CURRENT, shift);

   double range = high - low;
   if(range <= 0)
      return false;

   double body      = MathAbs(close - open);
   double upperWick = high - MathMax(open, close);
   double lowerWick = MathMin(open, close) - low;

   bool smallBody = (body <= range * 0.35);

   if(bullish)
      return (smallBody && lowerWick >= range * 0.5 && lowerWick > upperWick * 1.5);
   else
      return (smallBody && upperWick >= range * 0.5 && upperWick > lowerWick * 1.5);
  }

//+------------------------------------------------------------------+
//| Deteccion simple de Doji                                          |
//+------------------------------------------------------------------+
bool IsDoji(int shift)
  {
   double open  = iOpen(_Symbol, PERIOD_CURRENT, shift);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);
   double high  = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double low   = iLow(_Symbol, PERIOD_CURRENT, shift);
   double range = high - low;
   if(range <= 0)
      return false;
   double body = MathAbs(close - open);
   return (body <= range * 0.1);
  }

//+------------------------------------------------------------------+
//| Cuenta posiciones abiertas de este EA en este simbolo             |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(posInfo.SelectByIndex(i))
        {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Abre una posicion de compra                                       |
//+------------------------------------------------------------------+
void OpenBuy(double atrValue)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl, tp;
   if(InpUseATR_SLTP)
     {
      sl = ask - atrValue * InpSL_ATR_Mult;
      tp = ask + atrValue * InpTP_ATR_Mult;
     }
   else
     {
      sl = ask - InpSL_Points * point;
      tp = ask + InpTP_Points * point;
     }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   if(trade.Buy(InpFixedLot, _Symbol, ask, sl, tp, "RegimeSignal Buy"))
     {
      if(InpVerboseLog)
         Print("[XAUUSD_RegimeSignal_EA] COMPRA abierta. Lote=", InpFixedLot,
               " SL=", sl, " TP=", tp, " ATR=", atrValue);
     }
   else
     {
      Print("[XAUUSD_RegimeSignal_EA] ERROR al abrir COMPRA: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Abre una posicion de venta                                        |
//+------------------------------------------------------------------+
void OpenSell(double atrValue)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl, tp;
   if(InpUseATR_SLTP)
     {
      sl = bid + atrValue * InpSL_ATR_Mult;
      tp = bid - atrValue * InpTP_ATR_Mult;
     }
   else
     {
      sl = bid + InpSL_Points * point;
      tp = bid - InpTP_Points * point;
     }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   if(trade.Sell(InpFixedLot, _Symbol, bid, sl, tp, "RegimeSignal Sell"))
     {
      if(InpVerboseLog)
         Print("[XAUUSD_RegimeSignal_EA] VENTA abierta. Lote=", InpFixedLot,
               " SL=", sl, " TP=", tp, " ATR=", atrValue);
     }
   else
     {
      Print("[XAUUSD_RegimeSignal_EA] ERROR al abrir VENTA: ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Trailing stop basado en ATR para posiciones abiertas               |
//+------------------------------------------------------------------+
void ManageTrailing(double atrValue)
  {
   if(!InpUseTrailing)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic)
         continue;

      double openPrice = posInfo.PriceOpen();
      double curSL     = posInfo.StopLoss();
      double curTP     = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDist = bid - openPrice;
         if(profitDist > atrValue * InpTrailStart_ATR)
           {
            double newSL = NormalizeDouble(bid - atrValue * InpTrailStep_ATR, digits);
            if(newSL > curSL || curSL == 0)
              {
               trade.PositionModify(posInfo.Ticket(), newSL, curTP);
               if(InpVerboseLog)
                  Print("[XAUUSD_RegimeSignal_EA] Trailing BUY ticket=", posInfo.Ticket(), " nuevo SL=", newSL);
              }
           }
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDist = openPrice - ask;
         if(profitDist > atrValue * InpTrailStart_ATR)
           {
            double newSL = NormalizeDouble(ask + atrValue * InpTrailStep_ATR, digits);
            if(newSL < curSL || curSL == 0)
              {
               trade.PositionModify(posInfo.Ticket(), newSL, curTP);
               if(InpVerboseLog)
                  Print("[XAUUSD_RegimeSignal_EA] Trailing SELL ticket=", posInfo.Ticket(), " nuevo SL=", newSL);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Actualiza estadisticas en vivo desde el historial de deals         |
//+------------------------------------------------------------------+
void UpdateStatsFromLastDeal()
  {
   // Se llama tras detectar cierre de posicion; recorremos el historial reciente
   HistorySelect(TimeCurrent() - 3600, TimeCurrent() + 60);
   int total = HistoryDealsTotal();
   if(total <= 0)
      return;

   ulong dealTicket = HistoryDealGetTicket(total - 1);
   if(dealTicket == 0)
      return;

   if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)InpMagic)
      return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;
   if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                    HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                    HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

   statTotalTrades++;
   if(profit >= 0)
     {
      statWins++;
      statGrossProfit += profit;
      statSumProfitWins += profit;
     }
   else
     {
      statLosses++;
      statGrossLoss += MathAbs(profit);
      statSumLossLosses += profit;
     }
  }

//+------------------------------------------------------------------+
//| Imprime resumen estadistico en vivo                                |
//+------------------------------------------------------------------+
void PrintStatsSummary(string tag)
  {
   double winRate = (statTotalTrades > 0) ? (double)statWins / statTotalTrades * 100.0 : 0.0;
   double pf = (statGrossLoss > 0) ? statGrossProfit / statGrossLoss : 0.0;
   double avgWin = (statWins > 0) ? statSumProfitWins / statWins : 0.0;
   double avgLoss = (statLosses > 0) ? statSumLossLosses / statLosses : 0.0;
   double expectancy = (statTotalTrades > 0) ?
                        (statGrossProfit + statSumLossLosses) / statTotalTrades : 0.0;

   Print("======== [XAUUSD_RegimeSignal_EA] STATS ", tag, " ========");
   Print("Total ops: ", statTotalTrades, " | Wins: ", statWins, " | Losses: ", statLosses);
   Print("Win rate: ", DoubleToString(winRate, 2), "% | Profit Factor: ", DoubleToString(pf, 2));
   Print("Ganancia media: ", DoubleToString(avgWin, 2), " | Perdida media: ", DoubleToString(avgLoss, 2));
   Print("Expectativa media: ", DoubleToString(expectancy, 2));
   Print("===============================================================");
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction: detecta cierres para actualizar stats          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      UpdateStatsFromLastDeal();
     }
  }

//+------------------------------------------------------------------+
//| OnTick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   double atrBuf[1], adxBuf[1], plusDIBuf[1], minusDIBuf[1], rsiBuf[1];
   double macdMainBuf[1], macdSignalBuf[1], maNowBuf[1], maPastBuf[1];

   if(CopyBuffer(hATR, 0, 0, 1, atrBuf) <= 0) return;
   double atrValue = atrBuf[0];

   // Trailing se gestiona en cada tick, no solo en barra nueva
   ManageTrailing(atrValue);

   if(!IsNewBar())
      return;

   barCounter++;

   if(CopyBuffer(hADX, 0, 0, 1, adxBuf) <= 0) return;
   if(CopyBuffer(hADX, 1, 0, 1, plusDIBuf) <= 0) return;
   if(CopyBuffer(hADX, 2, 0, 1, minusDIBuf) <= 0) return;
   if(CopyBuffer(hRSI, 0, 0, 1, rsiBuf) <= 0) return;
   if(CopyBuffer(hMACD, 0, 0, 1, macdMainBuf) <= 0) return;
   if(CopyBuffer(hMACD, 1, 0, 1, macdSignalBuf) <= 0) return;
   if(CopyBuffer(hMA_trend, 0, 0, 1, maNowBuf) <= 0) return;
   if(CopyBuffer(hMA_trend, 0, InpTrendLookback, 1, maPastBuf) <= 0) return;

   double adxMain = adxBuf[0];
   double rsiValue = rsiBuf[0];
   double macdMain = macdMainBuf[0];
   double macdSignal = macdSignalBuf[0];

   double maSlopePct = 0.0;
   if(maPastBuf[0] != 0)
      maSlopePct = (maNowBuf[0] - maPastBuf[0]) / maPastBuf[0] * 100.0;

   ENUM_REGIME regime = ClassifyRegime(adxMain, maSlopePct);
   double trendPct = CalcTrendPct(InpTrendLookback);

   bool timeOK = TimeFilterOK();
   bool volOK  = VolatilityFilterOK(atrValue);
   bool regimeOK = RegimeAllowed(regime);

   bool pinBarBull = IsPinBar(1, true);
   bool pinBarBear = IsPinBar(1, false);
   bool doji       = IsDoji(1);

   if(InpVerboseLog)
     {
      Print("---- [XAUUSD_RegimeSignal_EA] Nueva barra #", barCounter, " ", TimeToString(TimeCurrent()), " ----");
      Print("Regimen=", RegimeToString(regime), " (permitido=", regimeOK, ") ADX=", DoubleToString(adxMain,2),
            " MA slope%=", DoubleToString(maSlopePct,3));
      Print("ATR=", DoubleToString(atrValue,5), " (filtro vol OK=", volOK, ")",
            " Hora OK=", timeOK, " TrendPct=", DoubleToString(trendPct,3),
            "% RSI=", DoubleToString(rsiValue,2),
            " MACD main/signal=", DoubleToString(macdMain,5), "/", DoubleToString(macdSignal,5));
      Print("PinBar alcista=", pinBarBull, " PinBar bajista=", pinBarBear, " Doji=", doji);
     }

   if(barCounter % InpStatsReportEveryNBars == 0 && barCounter > 0)
      PrintStatsSummary("PARCIAL bar#" + IntegerToString(barCounter));

   // Filtros duros comunes
   if(!timeOK || !volOK || !regimeOK)
     {
      if(InpVerboseLog)
         Print("Sin entrada: filtros duros no superados.");
      return;
     }

   if(CountOpenPositions() >= InpMaxOpenPositions)
     {
      if(InpVerboseLog)
         Print("Sin entrada: maximo de posiciones abiertas alcanzado.");
      return;
     }

   // ---- Logica de COMPRA ----
   bool buySignal = (regime == REGIME_STRONG_UPTREND || regime == REGIME_TRENDING ||
                      regime == REGIME_WEAK_TREND || regime == REGIME_RANGING);
   if(regime == REGIME_STRONG_DOWNTREND)
      buySignal = false; // no comprar en tendencia bajista fuerte

   if(InpRequirePinBarBuy && !pinBarBull)
      buySignal = false;

   // Confirmacion blanda con MACD/RSI: evita comprar con momentum claramente bajista extremo
   if(macdMain < macdSignal && rsiValue < 35)
      buySignal = false;

   // ---- Logica de VENTA ----
   bool sellSignal = (regime == REGIME_STRONG_DOWNTREND || regime == REGIME_TRENDING ||
                       regime == REGIME_WEAK_TREND || regime == REGIME_RANGING);
   if(regime == REGIME_STRONG_UPTREND)
      sellSignal = false; // no vender en tendencia alcista fuerte

   if(InpRequireTrendForSell && !(trendPct < InpSellTrendThreshold))
      sellSignal = false;

   if(macdMain > macdSignal && rsiValue > 65)
      sellSignal = false;

   // No permitir señales simultaneas contradictorias
   if(buySignal && sellSignal)
     {
      // Desempate: usar direccion de la MA
      if(maSlopePct > 0) sellSignal = false;
      else                buySignal  = false;
     }

   if(InpDryRunNoTrading)
     {
      if(InpVerboseLog)
         Print("[DRY RUN] No se abren operaciones. buySignal=", buySignal, " sellSignal=", sellSignal,
               " ATR_M1_real=", DoubleToString(atrValue, 5),
               " (usa este valor para calibrar InpVolTarget/InpVolTolerance)");
      return;
     }

   if(buySignal)
     {
      OpenBuy(atrValue);
     }
   else if(sellSignal)
     {
      OpenSell(atrValue);
     }
   else
     {
      if(InpVerboseLog)
         Print("Sin entrada: ninguna direccion cumple las condiciones tras filtros blandos.");
     }
  }
//+------------------------------------------------------------------+
