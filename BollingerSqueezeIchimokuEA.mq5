//+------------------------------------------------------------------+
//|                                BollingerSqueezeIchimokuEA.mq5     |
//|  Estrategia:                                                      |
//|   - Detecta el momento en que el precio SALE de un "cuello de     |
//|     botella" de Bollinger (squeeze previo + ancho expandiéndose)   |
//|   - Filtra dirección con la nube de Ichimoku (Kumo):                |
//|       BUY  si precio > nube (por encima de Senkou A y B)          |
//|       SELL si precio < nube (por debajo de Senkou A y B)          |
//|   - Filtro adicional: cruce %K/%D del Estocástico a favor de la    |
//|     dirección, para confirmar el momentum justo en la ruptura      |
//|   - SL / TP calculados con ATR                                    |
//|   - Multi-símbolo y multi-temporalidad simultáneo:                 |
//|     M10, M15, M30, H1, H2, H4, H8, H12, D1                        |
//|   - Resumen de resultados (trades/wins/losses/profit) por          |
//|     símbolo y temporalidad, impreso en el Journal                  |
//+------------------------------------------------------------------+
#property copyright "Javier"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//================= INPUTS =================
input string InpSymbols          = "EURUSD,GBPUSD,USDJPY,XAUUSD"; // símbolos separados por coma ("" = símbolo del gráfico)
input bool   InpUseM10           = true;
input bool   InpUseM15           = true;
input bool   InpUseM30           = true;
input bool   InpUseH1            = true;
input bool   InpUseH2            = true;
input bool   InpUseH4            = true;
input bool   InpUseH8            = true;
input bool   InpUseH12           = true;
input bool   InpUseD1            = true;

input int    InpBBPeriod         = 20;
input double InpBBDeviation      = 2.0;
input ENUM_APPLIED_PRICE InpBBPrice = PRICE_CLOSE;
input int    InpSqueezeLookback  = 50;     // nº de barras para el ancho medio
input double InpSqueezeThreshold = 0.50;   // squeeze si ancho actual < media * este factor
input int    InpBreakoutLookback = 5;      // nº de velas donde buscar el punto más estrecho reciente
input double InpExpansionFactor  = 1.20;   // dispara si el ancho actual creció esta proporción respecto al mínimo reciente

input int    InpTenkan           = 9;
input int    InpKijun            = 26;
input int    InpSenkouB          = 52;

input int    InpATRPeriod        = 14;
input double InpATR_SL_Mult      = 1.5;
const  double InpATR_TP_Mult     = 3.0;   // fijo: TP = precio ± 3 * ATR

input int    InpStochKPeriod     = 5;
input int    InpStochDPeriod     = 3;
input int    InpStochSlowing     = 3;
input ENUM_STO_PRICE InpStochPriceField = STO_LOWHIGH;
input bool   InpRequireStochCross = true;  // exige cruce %K/%D a favor de la dirección justo en la ruptura

input double InpLots             = 0.1;    // usado solo si InpUseMoneyBasedSizing = false
input bool   InpUseMoneyBasedSizing = true; // calcula el lote para que TP = InpTargetProfitMoney
input double InpTargetProfitMoney   = 50.0; // beneficio objetivo (en divisa de la cuenta) si toca TP

input bool   InpUseTrailing         = true;
input double InpTrailingATRMult      = 0.5; // distancia del trailing (fino) en múltiplos de ATR
input double InpTrailingStartATRMult = 1.0; // empieza a mover el SL solo si el profit supera este múltiplo de ATR

input int    InpMagicBase        = 20260721;
input int    InpSlippage         = 10;
input bool   InpCloseOnFlip      = true;   // cierra y revierte si aparece señal contraria
input int    InpHoldDays         = 10;     // cierre forzado por tiempo (0 = sin límite)
input int    InpMaxAgeDays       = 3;      // ignora señales de barras más viejas que esto (0 = sin límite)
input bool   InpVerboseLog       = true;   // imprime en el Journal el motivo de rechazo de cada señal

CTrade trade;

//================= ESTRUCTURA DE CONTEXTO =================
struct SContext
{
   string          symbol;
   ENUM_TIMEFRAMES tf;
   int             magic;
   int             bbHandle;
   int             ichiHandle;
   int             atrHandle;
   int             stoHandle;
   datetime        lastBar;
};

SContext ctx[];

struct SStats
{
   int    trades;
   int    wins;
   int    losses;
   double totalProfit;
};

SStats stats[];

//+------------------------------------------------------------------+
int ParseSymbols(const string list, string &out[])
{
   string src = list;
   if(src == "")
      src = _Symbol;

   int n = StringSplit(src, ',', out);
   for(int i=0; i<n; i++)
   {
      StringTrimLeft(out[i]);
      StringTrimRight(out[i]);
   }
   return n;
}

//+------------------------------------------------------------------+
int OnInit()
{
   ArrayResize(ctx, 0);

   string symList[];
   int n = ParseSymbols(InpSymbols, symList);

   ENUM_TIMEFRAMES tfs[9]      = { PERIOD_M10, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H2,
                                    PERIOD_H4, PERIOD_H8, PERIOD_H12, PERIOD_D1 };
   bool            useTf[9]    = { InpUseM10, InpUseM15, InpUseM30, InpUseH1, InpUseH2,
                                    InpUseH4, InpUseH8, InpUseH12, InpUseD1 };
   int             tfOffset[9] = { 1, 2, 3, 4, 5, 6, 7, 8, 9 };

   for(int s=0; s<n; s++)
   {
      if(symList[s] == "") continue;
      if(!SymbolSelect(symList[s], true))
      {
         PrintFormat("[WARN] No se pudo seleccionar el símbolo %s", symList[s]);
         continue;
      }

      for(int t=0; t<9; t++)
      {
         if(!useTf[t]) continue;

         SContext c;
         c.symbol     = symList[s];
         c.tf         = tfs[t];
         c.magic      = InpMagicBase + tfOffset[t]*100000 + s;
         c.bbHandle   = iBands(c.symbol, c.tf, InpBBPeriod, 0, InpBBDeviation, InpBBPrice);
         c.ichiHandle = iIchimoku(c.symbol, c.tf, InpTenkan, InpKijun, InpSenkouB);
         c.atrHandle  = iATR(c.symbol, c.tf, InpATRPeriod);
         c.stoHandle  = iStochastic(c.symbol, c.tf, InpStochKPeriod, InpStochDPeriod, InpStochSlowing, MODE_SMA, InpStochPriceField);
         c.lastBar    = 0;

         if(c.bbHandle==INVALID_HANDLE || c.ichiHandle==INVALID_HANDLE || c.atrHandle==INVALID_HANDLE || c.stoHandle==INVALID_HANDLE)
         {
            PrintFormat("[ERROR] Fallo creando indicadores para %s %s", c.symbol, EnumToString(c.tf));
            continue;
         }

         int sz = ArraySize(ctx);
         ArrayResize(ctx, sz+1);
         ctx[sz] = c;

         ArrayResize(stats, sz+1);
         stats[sz].trades = 0;
         stats[sz].wins = 0;
         stats[sz].losses = 0;
         stats[sz].totalProfit = 0.0;
      }
   }

   PrintFormat("EA inicializado con %d combinaciones símbolo/temporalidad", ArraySize(ctx));
   trade.SetDeviationInPoints(InpSlippage);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
// Resumen de resultados por símbolo y temporalidad
//+------------------------------------------------------------------+
void PrintSummary()
{
   Print("=========== RESUMEN POR SÍMBOLO / TEMPORALIDAD ===========");
   for(int i=0; i<ArraySize(ctx); i++)
   {
      double winRate = stats[i].trades > 0 ? (100.0 * stats[i].wins / stats[i].trades) : 0.0;
      PrintFormat("%-10s %-6s | trades=%-4d wins=%-4d losses=%-4d winRate=%5.1f%% profitTotal=%.2f",
                  ctx[i].symbol, EnumToString(ctx[i].tf),
                  stats[i].trades, stats[i].wins, stats[i].losses, winRate, stats[i].totalProfit);
   }
   Print("============================================================");
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintSummary();

   for(int i=0; i<ArraySize(ctx); i++)
   {
      if(ctx[i].bbHandle   != INVALID_HANDLE) IndicatorRelease(ctx[i].bbHandle);
      if(ctx[i].ichiHandle != INVALID_HANDLE) IndicatorRelease(ctx[i].ichiHandle);
      if(ctx[i].atrHandle  != INVALID_HANDLE) IndicatorRelease(ctx[i].atrHandle);
      if(ctx[i].stoHandle  != INVALID_HANDLE) IndicatorRelease(ctx[i].stoHandle);
   }
}

//+------------------------------------------------------------------+
// Registra el resultado de cada operación cerrada, por símbolo/temporalidad
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return; // solo cierres, no aperturas

   long   magic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);

   int idx = -1;
   for(int j=0; j<ArraySize(ctx); j++)
      if(ctx[j].magic == (int)magic && ctx[j].symbol == symbol) { idx = j; break; }
   if(idx < 0) return; // no es una operación de este EA

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                  + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                  + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   stats[idx].trades++;
   stats[idx].totalProfit += profit;
   if(profit >= 0) stats[idx].wins++;
   else             stats[idx].losses++;

   if(InpVerboseLog)
      PrintFormat("[RESULT] %s %s profit=%.2f | acumulado: trades=%d wins=%d losses=%d totalProfit=%.2f",
                  ctx[idx].symbol, EnumToString(ctx[idx].tf), profit,
                  stats[idx].trades, stats[idx].wins, stats[idx].losses, stats[idx].totalProfit);
}

//+------------------------------------------------------------------+
bool IsNewBar(SContext &c)
{
   datetime t[1];
   if(CopyTime(c.symbol, c.tf, 0, 1, t) != 1) return false;
   if(t[0] != c.lastBar)
   {
      c.lastBar = t[0];
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// Busca una posición abierta por este EA (símbolo + magic)
//+------------------------------------------------------------------+
bool GetOpenPosition(const string symbol, const int magic, ulong &ticket, long &posType, datetime &openTime)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic) continue;

      ticket   = tk;
      posType  = PositionGetInteger(POSITION_TYPE);
      openTime = (datetime)PositionGetInteger(POSITION_TIME);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void ClosePositionByTicket(const ulong ticket)
{
   trade.PositionClose(ticket);
}

//+------------------------------------------------------------------+
// Calcula el lote necesario para que, si el precio recorre tpDistance,
// el beneficio resultante sea aproximadamente targetProfit (en divisa de la cuenta)
//+------------------------------------------------------------------+
double CalcLotForTargetProfit(const string symbol, const double tpDistance, const double targetProfit)
{
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0 || tpDistance <= 0)
   {
      PrintFormat("[SIZING] %s no se pudo calcular lote por dinero (tickValue/tickSize inválidos), uso InpLots=%.2f", symbol, InpLots);
      return InpLots;
   }

   double valuePerLot = (tpDistance / tickSize) * tickValue; // beneficio con 1.0 lote si toca TP
   if(valuePerLot <= 0) return InpLots;

   double lot = targetProfit / valuePerLot;

   double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   if(InpVerboseLog)
      PrintFormat("[SIZING] %s tpDistance=%.5f valuePerLot=%.2f targetProfit=%.2f -> lot=%.2f",
                  symbol, tpDistance, valuePerLot, targetProfit, lot);

   return lot;
}

//+------------------------------------------------------------------+
void OpenTrade(SContext &c, const bool isBuy, const double atrValue)
{
   MqlTick tick;
   if(!SymbolInfoTick(c.symbol, tick)) return;

   double price = isBuy ? tick.ask : tick.bid;
   double sl, tp;
   int    digits = (int)SymbolInfoInteger(c.symbol, SYMBOL_DIGITS);

   double slDist = atrValue * InpATR_SL_Mult;
   double tpDist = atrValue * InpATR_TP_Mult;

   if(isBuy)
   {
      sl = price - slDist;
      tp = price + tpDist;
   }
   else
   {
      sl = price + slDist;
      tp = price - tpDist;
   }

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lot = InpUseMoneyBasedSizing ? CalcLotForTargetProfit(c.symbol, tpDist, InpTargetProfitMoney) : InpLots;
   if(lot <= 0)
   {
      PrintFormat("[ERROR] Lote calculado inválido para %s, no se abre orden", c.symbol);
      return;
   }

   trade.SetExpertMagicNumber(c.magic);

   string comment = StringFormat("BBsqueeze_%s_%s", c.symbol, EnumToString(c.tf));

   bool ok = isBuy
             ? trade.Buy(lot, c.symbol, price, sl, tp, comment)
             : trade.Sell(lot, c.symbol, price, sl, tp, comment);

   if(!ok)
      PrintFormat("[ERROR] Orden fallida %s %s dir=%s lot=%.2f ret=%d",
                  c.symbol, EnumToString(c.tf), isBuy ? "BUY" : "SELL", lot, trade.ResultRetcode());
   else
      PrintFormat("[OK] %s %s abierta en %s TF=%s lot=%.2f SL=%.5f TP=%.5f",
                  isBuy ? "BUY" : "SELL", c.symbol, c.symbol, EnumToString(c.tf), lot, sl, tp);
}

//+------------------------------------------------------------------+
// Evalúa squeeze + dirección Ichimoku para un contexto símbolo/TF
//+------------------------------------------------------------------+
void EvaluateContext(SContext &c)
{
   int need = MathMax(InpSqueezeLookback, InpBreakoutLookback) + 3;

   double upper[], lower[], middle[];
   ArraySetAsSeries(upper,  true);
   ArraySetAsSeries(lower,  true);
   ArraySetAsSeries(middle, true);

   if(CopyBuffer(c.bbHandle, 1, 0, need, upper)  <= 0) return; // banda superior
   if(CopyBuffer(c.bbHandle, 2, 0, need, lower)  <= 0) return; // banda inferior
   if(CopyBuffer(c.bbHandle, 0, 0, need, middle) <= 0) return; // banda media

   // Ancho de banda normalizado. bar[1] = última vela cerrada
   double curWidth = (upper[1] - lower[1]) / MathMax(middle[1], 1e-10);

   // Media de ancho calculada SIN incluir las últimas velas del posible squeeze,
   // para no contaminar la referencia con el propio cuello de botella
   double sumWidth = 0.0;
   int    count    = 0;
   for(int i = InpBreakoutLookback + 2; i < InpSqueezeLookback + InpBreakoutLookback + 2 && i < ArraySize(upper); i++)
   {
      double w = (upper[i] - lower[i]) / MathMax(middle[i], 1e-10);
      sumWidth += w;
      count++;
   }
   if(count == 0) return;
   double avgWidth = sumWidth / count;

   // Punto más estrecho (fondo del cuello de botella) dentro de las últimas InpBreakoutLookback velas cerradas
   double minRecentWidth = DBL_MAX;
   for(int i = 1; i <= InpBreakoutLookback && i < ArraySize(upper); i++)
   {
      double w = (upper[i] - lower[i]) / MathMax(middle[i], 1e-10);
      if(w < minRecentWidth) minRecentWidth = w;
   }

   // Evento de ruptura: hubo un squeeze reciente (mínimo por debajo del umbral)
   // y el ancho actual ya creció una proporción relevante desde ese mínimo
   bool wasSqueezed = minRecentWidth < avgWidth * InpSqueezeThreshold;
   bool isExpanding = curWidth > minRecentWidth * InpExpansionFactor;
   bool squeeze     = wasSqueezed && isExpanding;

   if(!squeeze)
   {
      if(InpVerboseLog)
         PrintFormat("[NO-BREAKOUT] %s %s curWidth=%.6f minRecentWidth=%.6f avgWidth=%.6f umbralSqueeze=%.6f umbralExpansion=%.6f wasSqueezed=%s isExpanding=%s",
                     c.symbol, EnumToString(c.tf), curWidth, minRecentWidth, avgWidth,
                     avgWidth*InpSqueezeThreshold, minRecentWidth*InpExpansionFactor,
                     wasSqueezed?"true":"false", isExpanding?"true":"false");
      return;
   }


   // Filtro de "frescura" de la señal (protege tras reinicios del EA)
   if(InpMaxAgeDays > 0)
   {
      datetime barTime[1];
      if(CopyTime(c.symbol, c.tf, 1, 1, barTime) == 1)
      {
         if((TimeCurrent() - barTime[0]) > InpMaxAgeDays * 86400)
            return;
      }
   }

   // Nube de Ichimoku (Kumo): Senkou Span A (buffer 2) y Senkou Span B (buffer 3)
   double spanA[], spanB[];
   ArraySetAsSeries(spanA, true);
   ArraySetAsSeries(spanB, true);
   if(CopyBuffer(c.ichiHandle, 2, 0, 3, spanA) <= 0) return;
   if(CopyBuffer(c.ichiHandle, 3, 0, 3, spanB) <= 0) return;

   double closePrice[];
   ArraySetAsSeries(closePrice, true);
   if(CopyClose(c.symbol, c.tf, 0, 3, closePrice) <= 0) return;

   double price = closePrice[1];
   double a = spanA[1];
   double b = spanB[1];

   if(a == 0.0 || b == 0.0) return; // nube aún no formada (proyección a futuro sin datos)

   double cloudTop    = MathMax(a, b);
   double cloudBottom = MathMin(a, b);

   bool wantBuy  = (price > cloudTop);
   bool wantSell = (price < cloudBottom);

   if(InpVerboseLog)
      PrintFormat("[SQUEEZE-OK] %s %s curWidth=%.6f minRecentWidth=%.6f | precio=%.5f cloudTop=%.5f cloudBottom=%.5f | wantBuy=%s wantSell=%s",
                  c.symbol, EnumToString(c.tf), curWidth, minRecentWidth,
                  price, cloudTop, cloudBottom,
                  wantBuy?"true":"false", wantSell?"true":"false");

   if(!wantBuy && !wantSell) return;

   // Confirmación de momentum con Estocástico: cruce %K/%D a favor de la dirección
   if(InpRequireStochCross)
   {
      double kBuf[], dBuf[];
      ArraySetAsSeries(kBuf, true);
      ArraySetAsSeries(dBuf, true);
      if(CopyBuffer(c.stoHandle, MAIN_LINE,   0, 3, kBuf) <= 0) return;
      if(CopyBuffer(c.stoHandle, SIGNAL_LINE, 0, 3, dBuf) <= 0) return;

      double kNow = kBuf[1], dNow = dBuf[1];
      double kPrev = kBuf[2], dPrev = dBuf[2];

      bool bullishCross = (kPrev <= dPrev) && (kNow > dNow);
      bool bearishCross = (kPrev >= dPrev) && (kNow < dNow);

      if(InpVerboseLog)
         PrintFormat("[STOCH] %s %s kNow=%.2f dNow=%.2f kPrev=%.2f dPrev=%.2f bullishCross=%s bearishCross=%s",
                     c.symbol, EnumToString(c.tf), kNow, dNow, kPrev, dPrev,
                     bullishCross?"true":"false", bearishCross?"true":"false");

      if(wantBuy  && !bullishCross) wantBuy  = false;
      if(wantSell && !bearishCross) wantSell = false;

      if(!wantBuy && !wantSell) return;
   }

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(c.atrHandle, 0, 0, 3, atrBuf) <= 0) return;
   double atrValue = atrBuf[1];
   if(atrValue <= 0) return;

   ulong    ticket;
   long     posType;
   datetime openTime;
   bool     hasPos = GetOpenPosition(c.symbol, c.magic, ticket, posType, openTime);

   if(hasPos)
   {
      bool isLong  = (posType == POSITION_TYPE_BUY);
      bool flipped = (isLong && wantSell) || (!isLong && wantBuy);

      if(flipped && InpCloseOnFlip)
      {
         ClosePositionByTicket(ticket);
         OpenTrade(c, wantBuy, atrValue);
      }
      // si no hay flip, se deja la posición viva (la gestiona OnTick con InpHoldDays)
   }
   else
   {
      OpenTrade(c, wantBuy, atrValue);
   }
}

//+------------------------------------------------------------------+
// Cierre forzado por tiempo máximo de mantenimiento (InpHoldDays)
//+------------------------------------------------------------------+
void ManageHoldTime()
{
   if(InpHoldDays <= 0) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      bool ours = false;
      for(int j=0; j<ArraySize(ctx); j++)
         if(ctx[j].magic == magic) { ours = true; break; }
      if(!ours) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if((TimeCurrent() - openTime) >= InpHoldDays * 86400)
         ClosePositionByTicket(tk);
   }
}

//+------------------------------------------------------------------+
// Trailing fino por ATR: solo mueve el SL a favor, nunca lo suelta
//+------------------------------------------------------------------+
void ManageTrailing()
{
   if(!InpUseTrailing) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;

      int magic = (int)PositionGetInteger(POSITION_MAGIC);
      int idx = -1;
      for(int j=0; j<ArraySize(ctx); j++)
         if(ctx[j].magic == magic) { idx = j; break; }
      if(idx < 0) continue; // no es una posición de este EA

      string symbol   = PositionGetString(POSITION_SYMBOL);
      long   type      = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL      = PositionGetDouble(POSITION_SL);
      double curTP      = PositionGetDouble(POSITION_TP);

      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      if(CopyBuffer(ctx[idx].atrHandle, 0, 0, 2, atrBuf) <= 0) continue;
      double atrValue = atrBuf[1];
      if(atrValue <= 0) continue;

      double trailDist = atrValue * InpTrailingATRMult;
      double startDist  = atrValue * InpTrailingStartATRMult;

      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) continue;

      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

      if(type == POSITION_TYPE_BUY)
      {
         double price = tick.bid;
         double profitDist = price - openPrice;
         if(profitDist < startDist) continue;

         double newSL = NormalizeDouble(price - trailDist, digits);
         if(newSL > curSL)
            trade.PositionModify(tk, newSL, curTP);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double price = tick.ask;
         double profitDist = openPrice - price;
         if(profitDist < startDist) continue;

         double newSL = NormalizeDouble(price + trailDist, digits);
         if(curSL == 0 || newSL < curSL)
            trade.PositionModify(tk, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   bool anyNewBar = false;

   for(int i=0; i<ArraySize(ctx); i++)
   {
      if(IsNewBar(ctx[i]))
      {
         EvaluateContext(ctx[i]);
         anyNewBar = true;
      }
   }
   ManageHoldTime();
   ManageTrailing();

   if(anyNewBar)
      PrintSummary();
}
//+------------------------------------------------------------------+