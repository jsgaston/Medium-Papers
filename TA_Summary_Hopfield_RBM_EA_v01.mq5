//+------------------------------------------------------------------+
//|  TA_Summary_Hopfield_RBM_EA.mq5                                   |
//|                                                                    |
//|  Replica funcional del "Technical Summary" de TradingView          |
//|  (Buy / Sell / Strong Buy / Strong Sell) usando medias móviles     |
//|  y osciladores clásicos con los umbrales estándar de la industria. |
//|                                                                    |
//|  Confirmación doble:                                               |
//|    - Red de Hopfield (energía asociativa, memorias buy/sell)       |
//|    - RBM binaria (Restricted Boltzmann Machine, estilo Hinton,     |
//|      comparación de energía libre F(v) entre modelo buy y sell)    |
//|                                                                    |
//|  TP = InpATR_TP_Normal x ATR en señales normales (Buy/Sell)        |
//|  TP = InpATR_TP_Strong x ATR en señales fuertes (Strong Buy/Sell)  |
//|  SL = InpATR_SL_Mult x ATR                                         |
//|  Break-even automático al alcanzar InpBreakevenTrigger% del TP     |
//|                                                                    |
//|  Multi-símbolo y multi-timeframe: listas separadas por coma.       |
//|                                                                    |
//|  AJUSTES v1.21:                                                    |
//|  - FIX: InpOnlyStrongTrades e InpOnlyNormalTrades estaban ambos     |
//|    activos a la vez, lo que bloqueaba TODAS las aperturas (por     |
//|    eso no hacía órdenes). Ahora ambos en false: se opera con       |
//|    normal Y strong.                                                 |
//|  - InpATR_TP_Strong = 1.0 (igual que el normal, según lo pedido).  |
//|                                                                    |
//|  NOTA IMPORTANTE:                                                  |
//|  TradingView no publica la fórmula exacta de su Technical Summary. |
//|  Esto es una réplica funcional con la misma filosofía (conteo de   |
//|  señales de MAs + osciladores), no un clon binario exacto.         |
//|  Los pesos/umbrales son ajustables desde los inputs. Ningún ajuste  |
//|  garantiza rentabilidad.                                            |
//+------------------------------------------------------------------+
#property copyright "Javier"
#property version   "1.21"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//====================================================================
// INPUTS
//====================================================================
input group "=== Símbolos / Timeframes ==="
input string InpSymbols          = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,NZDUSD,USDCHF,EURGBP,EURJPY,GBPJPY"; // Lista de símbolos separados por coma
input string InpTimeframes       = "H4,D1";                          // Lista de timeframes separados por coma

input group "=== Technical Summary ==="
input double InpStrongThreshold  = 0.55;   // |rating| >= esto => Strong Buy/Sell
input double InpNormalThreshold  = 0.20;   // |rating| >= esto => Buy/Sell
input int    InpADXTrendLevel    = 25;     // ADX mínimo para considerar tendencia direccional

input group "=== Hopfield / RBM ==="
input int    InpTrainBars        = 1500;   // Barras de histórico para entrenar
input int    InpForwardBars      = 8;      // Barras hacia delante para etiquetar patrón buy/sell
input double InpLabelATRMult     = 0.5;    // Movimiento mínimo (en ATR) para etiquetar patrón
input double InpHopfieldMargin   = 0.15;   // Margen mínimo de energía para confirmar (Hopfield)
input double InpRBMMargin        = 0.15;   // Margen mínimo de energía libre para confirmar (RBM)
input int    InpRBMHidden        = 4;      // Neuronas ocultas RBM (fijo a 4 internamente, informativo)
input int    InpRBMEpochs        = 150;    // Épocas de entrenamiento CD-1
input double InpRBMLearningRate  = 0.10;   // Learning rate RBM
input int    InpRetrainEveryBars = 100;    // Reentrenar Hopfield/RBM cada X velas (por par/TF)

input group "=== Gestión de riesgo / Trading ==="
input bool   InpAutoTrade        = true;   // false = solo señales en Journal, no abre operaciones
input bool   InpOnlyStrongTrades = false;  // true = solo abre operaciones en Strong Buy/Strong Sell
input bool   InpOnlyNormalTrades = false;  // true = solo abre operaciones en Buy/Sell normal (ignora Strong). NUNCA pongas este Y InpOnlyStrongTrades en true a la vez: se bloquearía TODO.
input string InpStrongAllowedTimeframes = "D1"; // Timeframes donde SÍ se permiten operaciones Strong, separados por coma (vacío = todos los timeframes). Ej: "D1" o "D1,H4". En Normal no aplica ningún filtro de timeframe.
input double InpRiskPercent      = 1.0;    // % de riesgo por operación (si 0, usa InpFixedLot)
input double InpFixedLot         = 0.01;   // Lote fijo si InpRiskPercent = 0
input int    InpATRPeriod        = 14;     // Periodo ATR
input double InpATR_SL_Mult      = 1.0;    // SL = ATR * este múltiplo
input double InpATR_TP_Normal    = 1.0;    // TP = ATR * este múltiplo (señal normal)
input double InpATR_TP_Strong    = 1.0;    // TP = ATR * este múltiplo (señal strong)
input double InpBreakevenTrigger = 0.5;    // Al recorrer esta fracción de la distancia al TP, mueve el SL a break-even (0 = desactivado)
input bool   InpTrailingEnabled     = true; // Activa el trailing stop que deja correr las ganancias más allá del TP fijo
input double InpTrailingStartATR    = 0.8;  // Cuando el precio ha recorrido esta fracción del ATR a favor, se quita el TP fijo y empieza el trailing
input double InpTrailingDistanceATR = 1.0;  // Distancia del trailing stop detrás del precio, en múltiplos de ATR
input double InpTrailingStepATR     = 0.1;  // Paso mínimo (en ATR) para mover el stop; evita modificaciones excesivas
input int    InpMagicBase        = 990000; // Magic base (se suma índice de par internamente)
input int    InpMaxBarsOpen      = 12;     // Nº máximo de velas (del TF del par) con la orden abierta. 0 = sin límite
input double InpMaxSpreadATRFrac = 0.20;   // No abrir si el spread actual > esta fracción del ATR (0 = sin filtro)
input int    InpMaxConsecutiveLosses = 4;  // Pausa ese par/tipo (normal o strong) tras N pérdidas seguidas (0 = sin límite)
input double InpMaxDrawdownPercent   = 15; // Si el equity cae este % desde su máximo histórico, se detienen nuevas aperturas (0 = sin límite)

input group "=== Operativa ==="
input int    InpTimerSeconds     = 30;     // Frecuencia de chequeo (segundos)
input bool   InpPrintTableAlways = true;   // Imprimir tabla en cada ciclo (si no, solo al cambiar señal)

//====================================================================
// CONSTANTES DEL MODELO
//====================================================================
#define NF 8   // número de features (Hopfield + RBM)
#define NH 4   // neuronas ocultas RBM
#define MAGIC_STEP 10          // separación entre magics de pares consecutivos (deja hueco normal/strong)
#define MAGIC_STRONG_OFFSET 1  // magic de señal "strong" = magic normal + este offset

//====================================================================
// ESTADO GLOBAL DE RIESGO (cortacircuitos de drawdown)
//====================================================================
double g_equityPeak = 0;
bool   g_tradingHalted = false;

//====================================================================
// TIMEFRAMES EN LOS QUE SE PERMITE OPERAR CON SEÑALES STRONG
//====================================================================
string g_strongAllowedTFs[];

bool StrongAllowedOnTF(string tf_name)
{
   if(ArraySize(g_strongAllowedTFs)==0) return true; // lista vacía = todos permitidos
   for(int i=0;i<ArraySize(g_strongAllowedTFs);i++)
      if(g_strongAllowedTFs[i]==tf_name) return true;
   return false;
}

//====================================================================
// ESTRUCTURA POR PAR/TIMEFRAME
//====================================================================
struct PairTF
{
   string   symbol;
   ENUM_TIMEFRAMES tf;
   string   tf_name;
   int      magic;          // magic para señales normales (Buy/Sell)
   int      magic_strong;   // magic para señales fuertes (Strong Buy/Strong Sell)

   // handles indicadores
   int h_ema10, h_ema20, h_ema50, h_ema100, h_ema200;
   int h_sma10, h_sma50, h_sma200;
   int h_rsi;
   int h_stoch;
   int h_cci;
   int h_adx;
   int h_macd;
   int h_wpr;
   int h_mom;
   int h_ao;
   int h_atr;

   // último resultado calculado (para tabla)
   double   last_rating;
   string   last_label;
   double   last_hopfield_dE;
   double   last_rbm_dF;
   bool     last_confirmed;
   int      last_dir;      // +1 buy, -1 sell, 0 none
   datetime last_bar_time;
   int      bars_since_train;

   // estadísticas TOTALES (normal+strong)
   double   total_profit;
   int      total_trades;
   int      wins;
   int      losses;
   double   hit_rate;

   // estadísticas señales NORMALES (Buy/Sell)
   double   normal_profit;
   int      normal_trades;
   int      normal_wins;
   double   normal_hit_rate;
   int      consecutive_losses_normal;

   // estadísticas señales FUERTES (Strong Buy/Strong Sell)
   double   strong_profit;
   int      strong_trades;
   int      strong_wins;
   double   strong_hit_rate;
   int      consecutive_losses_strong;

   // modelos entrenados
   bool     trained;
   double   W_buy[NF][NF];   // matriz Hopfield entrenada solo con patrones buy
   double   W_sell[NF][NF];  // matriz Hopfield entrenada solo con patrones sell

   double   rbm_W_buy[NF][NH];
   double   rbm_hbias_buy[NH];
   double   rbm_vbias_buy[NF];

   double   rbm_W_sell[NF][NH];
   double   rbm_hbias_sell[NH];
   double   rbm_vbias_sell[NF];
};

PairTF g_pairs[];

//====================================================================
// UTILIDADES GENERALES
//====================================================================
double Sigmoid(double x) { return 1.0/(1.0+MathExp(-x)); }
double Softplus(double x)
{
   if(x>30) return x;
   if(x<-30) return MathExp(x);
   return MathLog(1.0+MathExp(x));
}

string StringUpperCase(string s)
{
   string r = s;
   StringToUpper(r);
   return r;
}

ENUM_TIMEFRAMES StrToTF(string s)
{
   s = StringUpperCase(s);
   if(s=="M1")  return PERIOD_M1;
   if(s=="M5")  return PERIOD_M5;
   if(s=="M15") return PERIOD_M15;
   if(s=="M30") return PERIOD_M30;
   if(s=="H1")  return PERIOD_H1;
   if(s=="H4")  return PERIOD_H4;
   if(s=="D1")  return PERIOD_D1;
   if(s=="W1")  return PERIOD_W1;
   if(s=="MN1") return PERIOD_MN1;
   return PERIOD_CURRENT;
}

int SplitCSV(string src, string &out[])
{
   src = StringUpperCase(src);
   StringReplace(src, " ", "");
   return StringSplit(src, ',', out);
}

//====================================================================
// OnInit
//====================================================================
int OnInit()
{
   string symbols[], tfs[];
   int nSym = SplitCSV(InpSymbols, symbols);
   int nTf  = SplitCSV(InpTimeframes, tfs);

   if(nSym<=0 || nTf<=0)
   {
      Print("ERROR: revisa InpSymbols / InpTimeframes");
      return INIT_PARAMETERS_INCORRECT;
   }

   SplitCSV(InpStrongAllowedTimeframes, g_strongAllowedTFs);

   ArrayResize(g_pairs, nSym*nTf);
   int idx=0;
   for(int s=0; s<nSym; s++)
   {
      if(!SymbolSelect(symbols[s], true))
      {
         Print("Aviso: no se pudo seleccionar símbolo ", symbols[s]);
         continue;
      }
      for(int t=0; t<nTf; t++)
      {
         ENUM_TIMEFRAMES tf = StrToTF(tfs[t]);
         if(tf==PERIOD_CURRENT && tfs[t]!="M1")
         {
            Print("Timeframe no reconocido: ", tfs[t]);
            continue;
         }

         PairTF p;
         p.symbol       = symbols[s];
         p.tf           = tf;
         p.tf_name      = tfs[t];
         p.magic        = InpMagicBase + idx*MAGIC_STEP;
         p.magic_strong = p.magic + MAGIC_STRONG_OFFSET;
         p.last_rating = 0;
         p.last_label  = "N/A";
         p.last_hopfield_dE = 0;
         p.last_rbm_dF = 0;
         p.last_confirmed = false;
         p.last_dir = 0;
         p.last_bar_time = 0;
         p.bars_since_train = 0;
         p.total_profit = 0;  p.total_trades = 0;  p.wins = 0; p.losses = 0; p.hit_rate = 0;
         p.normal_profit = 0; p.normal_trades = 0; p.normal_wins = 0; p.normal_hit_rate = 0; p.consecutive_losses_normal = 0;
         p.strong_profit = 0; p.strong_trades = 0; p.strong_wins = 0; p.strong_hit_rate = 0; p.consecutive_losses_strong = 0;
         p.trained = false;

         p.h_ema10  = iMA(p.symbol, tf, 10, 0, MODE_EMA, PRICE_CLOSE);
         p.h_ema20  = iMA(p.symbol, tf, 20, 0, MODE_EMA, PRICE_CLOSE);
         p.h_ema50  = iMA(p.symbol, tf, 50, 0, MODE_EMA, PRICE_CLOSE);
         p.h_ema100 = iMA(p.symbol, tf, 100,0, MODE_EMA, PRICE_CLOSE);
         p.h_ema200 = iMA(p.symbol, tf, 200,0, MODE_EMA, PRICE_CLOSE);
         p.h_sma10  = iMA(p.symbol, tf, 10, 0, MODE_SMA, PRICE_CLOSE);
         p.h_sma50  = iMA(p.symbol, tf, 50, 0, MODE_SMA, PRICE_CLOSE);
         p.h_sma200 = iMA(p.symbol, tf, 200,0, MODE_SMA, PRICE_CLOSE);
         p.h_rsi    = iRSI(p.symbol, tf, 14, PRICE_CLOSE);
         p.h_stoch  = iStochastic(p.symbol, tf, 14,3,3, MODE_SMA, STO_LOWHIGH);
         p.h_cci    = iCCI(p.symbol, tf, 20, PRICE_TYPICAL);
         p.h_adx    = iADX(p.symbol, tf, 14);
         p.h_macd   = iMACD(p.symbol, tf, 12,26,9, PRICE_CLOSE);
         p.h_wpr    = iWPR(p.symbol, tf, 14);
         p.h_mom    = iMomentum(p.symbol, tf, 10, PRICE_CLOSE);
         p.h_ao     = iAO(p.symbol, tf);
         p.h_atr    = iATR(p.symbol, tf, InpATRPeriod);

         if(p.h_ema10==INVALID_HANDLE || p.h_rsi==INVALID_HANDLE || p.h_atr==INVALID_HANDLE)
         {
            Print("ERROR creando handles para ", p.symbol, " ", p.tf_name);
            continue;
         }

         g_pairs[idx] = p;
         idx++;
      }
   }
   ArrayResize(g_pairs, idx);

   for(int i=0; i<ArraySize(g_pairs); i++)
      TrainModels(g_pairs[i]);

   g_equityPeak = AccountInfoDouble(ACCOUNT_EQUITY);
   g_tradingHalted = false;

   if(InpOnlyStrongTrades && InpOnlyNormalTrades)
      Print("AVISO: InpOnlyStrongTrades e InpOnlyNormalTrades están ambos activos a la vez => no se abrirá NINGUNA operación. Revisa la configuración.");

   EventSetTimer(InpTimerSeconds);
   Print("EA iniciado con ", ArraySize(g_pairs), " combinaciones símbolo/timeframe.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   for(int i=0;i<ArraySize(g_pairs);i++)
   {
      IndicatorRelease(g_pairs[i].h_ema10);
      IndicatorRelease(g_pairs[i].h_ema20);
      IndicatorRelease(g_pairs[i].h_ema50);
      IndicatorRelease(g_pairs[i].h_ema100);
      IndicatorRelease(g_pairs[i].h_ema200);
      IndicatorRelease(g_pairs[i].h_sma10);
      IndicatorRelease(g_pairs[i].h_sma50);
      IndicatorRelease(g_pairs[i].h_sma200);
      IndicatorRelease(g_pairs[i].h_rsi);
      IndicatorRelease(g_pairs[i].h_stoch);
      IndicatorRelease(g_pairs[i].h_cci);
      IndicatorRelease(g_pairs[i].h_adx);
      IndicatorRelease(g_pairs[i].h_macd);
      IndicatorRelease(g_pairs[i].h_wpr);
      IndicatorRelease(g_pairs[i].h_mom);
      IndicatorRelease(g_pairs[i].h_ao);
      IndicatorRelease(g_pairs[i].h_atr);
   }
}

//====================================================================
// OnTimer: recorre todos los pares, evalúa si hay barra nueva
//====================================================================
void OnTimer()
{
   CheckEquityCircuitBreaker();

   for(int i=0;i<ArraySize(g_pairs);i++)
      EvaluatePair(g_pairs[i]);

   CheckBreakeven();
   CheckTrailingStop();
   CheckMaxBarsOpen();

   if(InpPrintTableAlways)
      PrintResultsTable();
}

void OnTick() {} // toda la lógica va por OnTimer para no atarse al símbolo del chart

//====================================================================
// CORTACIRCUITOS DE DRAWDOWN GLOBAL
// Si el equity cae InpMaxDrawdownPercent% desde su máximo histórico,
// se detienen nuevas aperturas. Las posiciones abiertas se siguen
// gestionando con su SL/TP/break-even/tiempo máximo normalmente.
// Se reanuda cuando el equity se recupera a la mitad de ese drawdown.
//====================================================================
void CheckEquityCircuitBreaker()
{
   if(InpMaxDrawdownPercent <= 0) return; // desactivado

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak) g_equityPeak = equity;

   if(g_equityPeak<=0) return;
   double ddPercent = 100.0 * (g_equityPeak - equity) / g_equityPeak;

   if(!g_tradingHalted && ddPercent >= InpMaxDrawdownPercent)
   {
      g_tradingHalted = true;
      PrintFormat("*** CORTACIRCUITOS: drawdown %.2f%% >= %.2f%%. Se detienen NUEVAS aperturas hasta que el equity se recupere. ***",
                  ddPercent, InpMaxDrawdownPercent);
   }
   else if(g_tradingHalted && ddPercent <= InpMaxDrawdownPercent*0.5)
   {
      g_tradingHalted = false;
      PrintFormat("*** Drawdown recuperado a %.2f%%. Se reanudan nuevas aperturas. ***", ddPercent);
   }
}

//====================================================================

//====================================================================
// TRAILING STOP: cuando el precio ha recorrido una fracción del ATR
// a favor, se quita el TP fijo (para dejar correr la ganancia si la
// tendencia sigue) y se activa un stop que persigue al precio a una
// distancia de InpTrailingDistanceATR x ATR. Así una operación con
// TP=1xATR puede terminar capturando 2x, 3x ATR o más si el
// movimiento continúa, en vez de cerrarse justo en el TP original.
//====================================================================
void CheckTrailingStop()
{
   if(!InpTrailingEnabled) return;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      int found=-1;
      for(int k=0;k<ArraySize(g_pairs);k++)
      {
         if(g_pairs[k].magic==magic || g_pairs[k].magic_strong==magic)
         { found=k; break; }
      }
      if(found==-1) continue; // no es una posición de este EA

      string symbol = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long type = PositionGetInteger(POSITION_TYPE);

      double atr[]; ArraySetAsSeries(atr,true);
      if(CopyBuffer(g_pairs[found].h_atr,0,0,1,atr)<1) continue;
      double atrVal = atr[0];
      if(atrVal<=0) continue;

      double stepPrice = InpTrailingStepATR * atrVal;
      double trailDist  = InpTrailingDistanceATR * atrVal;

      if(type==POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double achieved = bid - openPrice;

         if(achieved >= InpTrailingStartATR*atrVal)
         {
            double newSL = bid - trailDist;
            // Primera activación: quitamos el TP fijo para dejar correr la ganancia.
            double tpToSet = (currentTP!=0) ? 0.0 : currentTP;
            if(currentSL < newSL - stepPrice || currentTP!=0)
               trade.PositionModify(ticket, MathMax(currentSL, newSL), tpToSet);
         }
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double achieved = openPrice - ask;

         if(achieved >= InpTrailingStartATR*atrVal)
         {
            double newSL = ask + trailDist;
            double tpToSet = (currentTP!=0) ? 0.0 : currentTP;
            if((currentSL==0 || currentSL > newSL + stepPrice) || currentTP!=0)
               trade.PositionModify(ticket, (currentSL==0 ? newSL : MathMin(currentSL, newSL)), tpToSet);
         }
      }
   }
}

//====================================================================
// BREAK-EVEN AUTOMÁTICO: mueve el SL a la entrada al recorrer parte
// del camino hacia el TP. Convierte posibles reversiones en operaciones
// neutras en vez de pérdidas.
//====================================================================
void CheckBreakeven()
{
   if(InpBreakevenTrigger <= 0) return; // desactivado

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      int found=-1;
      for(int k=0;k<ArraySize(g_pairs);k++)
      {
         if(g_pairs[k].magic==magic || g_pairs[k].magic_strong==magic)
         { found=k; break; }
      }
      if(found==-1) continue; // no es una posición de este EA

      string symbol = PositionGetString(POSITION_SYMBOL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long type = PositionGetInteger(POSITION_TYPE);

      if(currentTP==0) continue; // sin TP definido, no podemos calcular el trigger

      double totalDist = MathAbs(currentTP - openPrice);
      if(totalDist<=0) continue;

      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double buffer = 3 * point; // pequeño colchón para cubrir spread/comisión

      if(type==POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double achieved = bid - openPrice;
         double newSL = openPrice + buffer;
         if(achieved >= InpBreakevenTrigger*totalDist && currentSL < newSL)
            trade.PositionModify(ticket, newSL, currentTP);
      }
      else if(type==POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double achieved = openPrice - ask;
         double newSL = openPrice - buffer;
         if(achieved >= InpBreakevenTrigger*totalDist && (currentSL==0 || currentSL > newSL))
            trade.PositionModify(ticket, newSL, currentTP);
      }
   }
}

//====================================================================
// CIERRE POR TIEMPO MÁXIMO EN VELAS ABIERTAS
//====================================================================
void CheckMaxBarsOpen()
{
   if(InpMaxBarsOpen <= 0) return; // desactivado

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      string symbol = PositionGetString(POSITION_SYMBOL);

      int found=-1;
      for(int k=0;k<ArraySize(g_pairs);k++)
      {
         if(g_pairs[k].magic==magic || g_pairs[k].magic_strong==magic)
         { found=k; break; }
      }
      if(found==-1) continue; // no es una posición de este EA

      ENUM_TIMEFRAMES tf = g_pairs[found].tf;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      int barsElapsed = iBarShift(symbol, tf, openTime, false);
      if(barsElapsed==-1) continue;

      if(barsElapsed >= InpMaxBarsOpen)
      {
         PrintFormat("%s %s | Cerrando ticket #%I64u por tiempo máximo alcanzado (%d velas >= %d)",
                     symbol, g_pairs[found].tf_name, ticket, barsElapsed, InpMaxBarsOpen);
         trade.PositionClose(ticket);
      }
   }
}

//====================================================================
// EVALUACIÓN DE UN PAR: TA Summary + confirmación Hopfield/RBM + trade
//====================================================================
void EvaluatePair(PairTF &p)
{
   datetime barTime[];
   ArraySetAsSeries(barTime, true);
   if(CopyTime(p.symbol, p.tf, 0, 1, barTime) < 1) return;
   if(barTime[0] == p.last_bar_time) return; // aún no hay barra nueva
   p.last_bar_time = barTime[0];

   // --- reentrenamiento periódico de Hopfield/RBM cada InpRetrainEveryBars velas ---
   p.bars_since_train++;
   if(p.bars_since_train >= InpRetrainEveryBars)
   {
      PrintFormat("Reentrenando Hopfield/RBM para %s %s (cada %d velas)...", p.symbol, p.tf_name, InpRetrainEveryBars);
      TrainModels(p);
      p.bars_since_train = 0;
   }

   double rating; string label; int dir;
   if(!ComputeTASummary(p, rating, label, dir)) return;

   p.last_rating = rating;
   p.last_label  = label;
   p.last_dir    = dir;

   if(dir==0)
   {
      p.last_confirmed = false;
      return;
   }

   double feat[NF];
   if(!BuildFeatureVector(p, feat)) { p.last_confirmed=false; return; }

   double dE = HopfieldEnergy(feat, p.W_sell) - HopfieldEnergy(feat, p.W_buy); // >0 => más a favor de buy
   double dF = RBMFreeEnergy(feat, p.rbm_W_sell, p.rbm_hbias_sell, p.rbm_vbias_sell)
             - RBMFreeEnergy(feat, p.rbm_W_buy,  p.rbm_hbias_buy,  p.rbm_vbias_buy); // >0 => más a favor de buy

   p.last_hopfield_dE = dE;
   p.last_rbm_dF = dF;

   bool hopfield_ok = (dir>0 && dE >  InpHopfieldMargin) || (dir<0 && dE < -InpHopfieldMargin);
   bool rbm_ok      = (dir>0 && dF >  InpRBMMargin)      || (dir<0 && dF < -InpRBMMargin);

   p.last_confirmed = hopfield_ok && rbm_ok;

   bool strong = (label=="Strong Buy" || label=="Strong Sell");

   bool allowedToTrade;
   if(strong) allowedToTrade = !InpOnlyNormalTrades && StrongAllowedOnTF(p.tf_name);
   else       allowedToTrade = !InpOnlyStrongTrades;

   if(p.last_confirmed && InpAutoTrade && allowedToTrade)
      TryOpenTrade(p, dir, strong);

   if(!InpPrintTableAlways)
      PrintResultsTable();
}

//====================================================================
// TA SUMMARY (réplica funcional del Technical Summary de TradingView)
//====================================================================
bool ComputeTASummary(PairTF &p, double &rating, string &label, int &dir)
{
   double close[];
   ArraySetAsSeries(close,true);
   if(CopyClose(p.symbol,p.tf,0,3,close)<3) return false;
   double c = close[0];

   int votes=0; double sum=0;

   int maHandles[8];
   maHandles[0]=p.h_ema10; maHandles[1]=p.h_ema20; maHandles[2]=p.h_ema50;
   maHandles[3]=p.h_ema100; maHandles[4]=p.h_ema200;
   maHandles[5]=p.h_sma10; maHandles[6]=p.h_sma50; maHandles[7]=p.h_sma200;

   for(int i=0;i<8;i++)
   {
      double v[]; ArraySetAsSeries(v,true);
      if(CopyBuffer(maHandles[i],0,0,1,v)<1) continue;
      sum += (c>v[0]) ? 1.0 : ((c<v[0]) ? -1.0 : 0.0);
      votes++;
   }

   { double v[]; ArraySetAsSeries(v,true);
     if(CopyBuffer(p.h_rsi,0,0,1,v)==1)
     { sum += (v[0]<30)?1.0:((v[0]>70)?-1.0:0.0); votes++; } }

   { double v[]; ArraySetAsSeries(v,true);
     if(CopyBuffer(p.h_stoch,0,0,1,v)==1)
     { sum += (v[0]<20)?1.0:((v[0]>80)?-1.0:0.0); votes++; } }

   { double v[]; ArraySetAsSeries(v,true);
     if(CopyBuffer(p.h_cci,0,0,1,v)==1)
     { sum += (v[0]<-100)?1.0:((v[0]>100)?-1.0:0.0); votes++; } }

   { double v[]; ArraySetAsSeries(v,true);
     if(CopyBuffer(p.h_wpr,0,0,1,v)==1)
     { sum += (v[0]<-80)?1.0:((v[0]>-20)?-1.0:0.0); votes++; } }

   { double v[]; ArraySetAsSeries(v,true);
     if(CopyBuffer(p.h_mom,0,0,1,v)==1)
     { sum += (v[0]>100)?1.0:((v[0]<100)?-1.0:0.0); votes++; } }

   { double m[],s[]; ArraySetAsSeries(m,true); ArraySetAsSeries(s,true);
     if(CopyBuffer(p.h_macd,0,0,1,m)==1 && CopyBuffer(p.h_macd,1,0,1,s)==1)
     { sum += (m[0]>s[0])?1.0:((m[0]<s[0])?-1.0:0.0); votes++; } }

   { double v[]; ArraySetAsSeries(v,true);
     if(CopyBuffer(p.h_ao,0,0,1,v)==1)
     { sum += (v[0]>0)?1.0:((v[0]<0)?-1.0:0.0); votes++; } }

   { double adx[],diP[],diM[];
     ArraySetAsSeries(adx,true); ArraySetAsSeries(diP,true); ArraySetAsSeries(diM,true);
     if(CopyBuffer(p.h_adx,0,0,1,adx)==1 && CopyBuffer(p.h_adx,1,0,1,diP)==1 && CopyBuffer(p.h_adx,2,0,1,diM)==1)
     {
        if(adx[0] >= InpADXTrendLevel)
           sum += (diP[0]>diM[0]) ? 1.0 : -1.0;
        votes++;
     } }

   if(votes==0) return false;
   rating = sum/votes;

   if(rating >= InpStrongThreshold)      { label="Strong Buy";  dir=+1; }
   else if(rating >= InpNormalThreshold) { label="Buy";         dir=+1; }
   else if(rating <= -InpStrongThreshold){ label="Strong Sell"; dir=-1; }
   else if(rating <= -InpNormalThreshold){ label="Sell";        dir=-1; }
   else                                  { label="Neutral";     dir=0;  }

   return true;
}

//====================================================================
// FEATURE VECTOR (8 features bipolares {-1,+1}) para Hopfield/RBM
//====================================================================
bool BuildFeatureVector(PairTF &p, double &feat[])
{
   double e10[],e50[],e200[],rsi[],macdM[],macdS[],mom[],cci[],diP[],diM[],ao[];
   ArraySetAsSeries(e10,true); ArraySetAsSeries(e50,true); ArraySetAsSeries(e200,true);
   ArraySetAsSeries(rsi,true); ArraySetAsSeries(macdM,true); ArraySetAsSeries(macdS,true);
   ArraySetAsSeries(mom,true); ArraySetAsSeries(cci,true);
   ArraySetAsSeries(diP,true); ArraySetAsSeries(diM,true); ArraySetAsSeries(ao,true);

   if(CopyBuffer(p.h_ema10,0,0,1,e10)<1)  return false;
   if(CopyBuffer(p.h_ema50,0,0,1,e50)<1)  return false;
   if(CopyBuffer(p.h_ema200,0,0,1,e200)<1) return false;
   if(CopyBuffer(p.h_rsi,0,0,1,rsi)<1) return false;
   if(CopyBuffer(p.h_macd,0,0,1,macdM)<1) return false;
   if(CopyBuffer(p.h_macd,1,0,1,macdS)<1) return false;
   if(CopyBuffer(p.h_mom,0,0,1,mom)<1) return false;
   if(CopyBuffer(p.h_cci,0,0,1,cci)<1) return false;
   if(CopyBuffer(p.h_adx,1,0,1,diP)<1) return false;
   if(CopyBuffer(p.h_adx,2,0,1,diM)<1) return false;
   if(CopyBuffer(p.h_ao,0,0,1,ao)<1) return false;

   feat[0] = (e10[0]  >= e50[0])  ? 1.0 : -1.0;
   feat[1] = (e50[0]  >= e200[0]) ? 1.0 : -1.0;
   feat[2] = (rsi[0]  >= 50.0)    ? 1.0 : -1.0;
   feat[3] = (macdM[0]>= macdS[0])? 1.0 : -1.0;
   feat[4] = (mom[0]  >= 100.0)   ? 1.0 : -1.0;
   feat[5] = (cci[0]  >= 0.0)     ? 1.0 : -1.0;
   feat[6] = (diP[0]  >= diM[0])  ? 1.0 : -1.0;
   feat[7] = (ao[0]   >= 0.0)     ? 1.0 : -1.0;
   return true;
}

//====================================================================
// HOPFIELD: entrenamiento Hebbiano y energía
//====================================================================
void HopfieldTrain(double &patterns[][NF], int n, double &W[][NF])
{
   for(int i=0;i<NF;i++)
      for(int j=0;j<NF;j++)
         W[i][j]=0;

   if(n==0) return;

   for(int k=0;k<n;k++)
      for(int i=0;i<NF;i++)
         for(int j=0;j<NF;j++)
            if(i!=j)
               W[i][j] += patterns[k][i]*patterns[k][j];

   for(int i=0;i<NF;i++)
      for(int j=0;j<NF;j++)
         W[i][j] /= n;
}

double HopfieldEnergy(double &pat[], double &W[][NF])
{
   double e=0;
   for(int i=0;i<NF;i++)
      for(int j=0;j<NF;j++)
         e += pat[i]*W[i][j]*pat[j];
   return -0.5*e;
}

//====================================================================
// RBM binaria: entrenamiento CD-1 y energía libre
//====================================================================
void RBMTrain(double &patterns01[][NF], int n, double &W[][NH], double &hbias[], double &vbias[])
{
   MathSrand((int)TimeLocal());
   for(int i=0;i<NF;i++)
      for(int j=0;j<NH;j++)
         W[i][j] = (MathRand()/32767.0 - 0.5)*0.2;
   for(int j=0;j<NH;j++) hbias[j]=0;
   for(int i=0;i<NF;i++) vbias[i]=0;

   if(n==0) return;

   double lr = InpRBMLearningRate;
   for(int epoch=0; epoch<InpRBMEpochs; epoch++)
   {
      for(int k=0;k<n;k++)
      {
         double v0[NF];
         for(int i=0;i<NF;i++) v0[i]=patterns01[k][i];

         double h0p[NH], h0s[NH];
         for(int j=0;j<NH;j++)
         {
            double a=hbias[j];
            for(int i=0;i<NF;i++) a += v0[i]*W[i][j];
            h0p[j]=Sigmoid(a);
            h0s[j]=(MathRand()/32767.0 < h0p[j]) ? 1.0 : 0.0;
         }

         double v1p[NF], v1s[NF];
         for(int i=0;i<NF;i++)
         {
            double a=vbias[i];
            for(int j=0;j<NH;j++) a += h0s[j]*W[i][j];
            v1p[i]=Sigmoid(a);
            v1s[i]=(MathRand()/32767.0 < v1p[i]) ? 1.0 : 0.0;
         }

         double h1p[NH];
         for(int j=0;j<NH;j++)
         {
            double a=hbias[j];
            for(int i=0;i<NF;i++) a += v1s[i]*W[i][j];
            h1p[j]=Sigmoid(a);
         }

         for(int i=0;i<NF;i++)
            for(int j=0;j<NH;j++)
               W[i][j] += lr*(v0[i]*h0p[j] - v1s[i]*h1p[j]);

         for(int i=0;i<NF;i++) vbias[i] += lr*(v0[i]-v1s[i]);
         for(int j=0;j<NH;j++) hbias[j] += lr*(h0p[j]-h1p[j]);
      }
   }
}

double RBMFreeEnergy(double &feat_bipolar[], double &W[][NH], double &hbias[], double &vbias[])
{
   double v[NF];
   for(int i=0;i<NF;i++) v[i] = (feat_bipolar[i]>0) ? 1.0 : 0.0;

   double term1=0;
   for(int i=0;i<NF;i++) term1 += v[i]*vbias[i];

   double term2=0;
   for(int j=0;j<NH;j++)
   {
      double a=hbias[j];
      for(int i=0;i<NF;i++) a += v[i]*W[i][j];
      term2 += Softplus(a);
   }
   return -term1 - term2;
}

//====================================================================
// ENTRENAMIENTO: recolecta patrones históricos y entrena Hopfield+RBM
//====================================================================
void TrainModels(PairTF &p)
{
   int bars = InpTrainBars;
   double e10[],e50[],e200[],rsi[],macdM[],macdS[],mom[],cci[],diP[],diM[],ao[],atr[],close[];
   ArraySetAsSeries(e10,true); ArraySetAsSeries(e50,true); ArraySetAsSeries(e200,true);
   ArraySetAsSeries(rsi,true); ArraySetAsSeries(macdM,true); ArraySetAsSeries(macdS,true);
   ArraySetAsSeries(mom,true); ArraySetAsSeries(cci,true);
   ArraySetAsSeries(diP,true); ArraySetAsSeries(diM,true); ArraySetAsSeries(ao,true);
   ArraySetAsSeries(atr,true); ArraySetAsSeries(close,true);

   int got = MathMin(bars, Bars(p.symbol,p.tf)-InpForwardBars-5);
   if(got < 100)
   {
      Print("Histórico insuficiente para entrenar ", p.symbol," ",p.tf_name,". Se usan matrices neutras.");
      return;
   }

   if(CopyBuffer(p.h_ema10,0,0,got,e10)<got)   return;
   if(CopyBuffer(p.h_ema50,0,0,got,e50)<got)   return;
   if(CopyBuffer(p.h_ema200,0,0,got,e200)<got) return;
   if(CopyBuffer(p.h_rsi,0,0,got,rsi)<got)     return;
   if(CopyBuffer(p.h_macd,0,0,got,macdM)<got)  return;
   if(CopyBuffer(p.h_macd,1,0,got,macdS)<got)  return;
   if(CopyBuffer(p.h_mom,0,0,got,mom)<got)     return;
   if(CopyBuffer(p.h_cci,0,0,got,cci)<got)     return;
   if(CopyBuffer(p.h_adx,1,0,got,diP)<got)     return;
   if(CopyBuffer(p.h_adx,2,0,got,diM)<got)     return;
   if(CopyBuffer(p.h_ao,0,0,got,ao)<got)       return;
   if(CopyBuffer(p.h_atr,0,0,got,atr)<got)     return;
   if(CopyClose(p.symbol,p.tf,0,got,close)<got) return;

   double buyPatterns[][NF];
   double sellPatterns[][NF];
   ArrayResize(buyPatterns, got);
   ArrayResize(sellPatterns, got);
   int nBuy=0, nSell=0;

   for(int idx = got-1; idx >= InpForwardBars; idx--)
   {
      double feat[NF];
      feat[0] = (e10[idx]  >= e50[idx])  ? 1.0 : -1.0;
      feat[1] = (e50[idx]  >= e200[idx]) ? 1.0 : -1.0;
      feat[2] = (rsi[idx]  >= 50.0)      ? 1.0 : -1.0;
      feat[3] = (macdM[idx]>= macdS[idx])? 1.0 : -1.0;
      feat[4] = (mom[idx]  >= 100.0)     ? 1.0 : -1.0;
      feat[5] = (cci[idx]  >= 0.0)       ? 1.0 : -1.0;
      feat[6] = (diP[idx]  >= diM[idx])  ? 1.0 : -1.0;
      feat[7] = (ao[idx]   >= 0.0)       ? 1.0 : -1.0;

      double futureClose = close[idx-InpForwardBars];
      double moveInATR = (futureClose - close[idx]) / MathMax(atr[idx], _Point);

      if(moveInATR >= InpLabelATRMult)
      {
         for(int f=0;f<NF;f++) buyPatterns[nBuy][f]=feat[f];
         nBuy++;
      }
      else if(moveInATR <= -InpLabelATRMult)
      {
         for(int f=0;f<NF;f++) sellPatterns[nSell][f]=feat[f];
         nSell++;
      }
   }
   ArrayResize(buyPatterns, nBuy);
   ArrayResize(sellPatterns, nSell);

   HopfieldTrain(buyPatterns,  nBuy,  p.W_buy);
   HopfieldTrain(sellPatterns, nSell, p.W_sell);

   double buy01[][NF]; ArrayResize(buy01, nBuy);
   for(int k=0;k<nBuy;k++) for(int f=0;f<NF;f++) buy01[k][f] = (buyPatterns[k][f]>0)?1.0:0.0;
   double sell01[][NF]; ArrayResize(sell01, nSell);
   for(int k=0;k<nSell;k++) for(int f=0;f<NF;f++) sell01[k][f] = (sellPatterns[k][f]>0)?1.0:0.0;

   RBMTrain(buy01,  nBuy,  p.rbm_W_buy,  p.rbm_hbias_buy,  p.rbm_vbias_buy);
   RBMTrain(sell01, nSell, p.rbm_W_sell, p.rbm_hbias_sell, p.rbm_vbias_sell);

   p.trained = true;
   PrintFormat("Modelos entrenados %s %s | patrones buy=%d sell=%d", p.symbol, p.tf_name, nBuy, nSell);
}

//====================================================================
// APERTURA DE OPERACIONES
//====================================================================
void TryOpenTrade(PairTF &p, int dir, bool strong)
{
   // Cortacircuitos de drawdown global: no abrir nuevas operaciones si está activo.
   if(g_tradingHalted) return;

   // Cooldown por racha de pérdidas consecutivas (por par/tipo).
   int streak = strong ? p.consecutive_losses_strong : p.consecutive_losses_normal;
   if(InpMaxConsecutiveLosses > 0 && streak >= InpMaxConsecutiveLosses)
      return;

   int magicToUse = strong ? p.magic_strong : p.magic;

   // ya hay posición abierta para este símbolo+timeframe (normal o strong)?
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(PositionGetString(POSITION_SYMBOL)==p.symbol && (m==p.magic || m==p.magic_strong))
         return; // ya hay una operación abierta para este par/timeframe
   }

   double atr[]; ArraySetAsSeries(atr,true);
   if(CopyBuffer(p.h_atr,0,0,1,atr)<1) return;
   double atrVal = atr[0];
   if(atrVal<=0) return;

   // Filtro de spread: si el coste de entrar (spread) es demasiado grande respecto
   // al ATR, no merece la pena abrir (el spread se comería una fracción excesiva del TP).
   if(InpMaxSpreadATRFrac > 0)
   {
      double ask = SymbolInfoDouble(p.symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(p.symbol, SYMBOL_BID);
      double spread = ask - bid;
      if(spread > atrVal * InpMaxSpreadATRFrac)
         return;
   }

   double tpMult = strong ? InpATR_TP_Strong : InpATR_TP_Normal;
   double slDist = atrVal * InpATR_SL_Mult;
   double tpDist = atrVal * tpMult;

   double price = (dir>0) ? SymbolInfoDouble(p.symbol,SYMBOL_ASK) : SymbolInfoDouble(p.symbol,SYMBOL_BID);
   double sl = (dir>0) ? price - slDist : price + slDist;
   double tp = (dir>0) ? price + tpDist : price - tpDist;

   double lot = CalcLot(p.symbol, slDist);
   if(lot<=0) return;

   trade.SetExpertMagicNumber(magicToUse);
   bool ok;
   string cmt = "TA_Hopfield_RBM_"+p.tf_name+(strong?"_STRONG":"_NORMAL");
   if(dir>0) ok = trade.Buy(lot, p.symbol, price, sl, tp, cmt);
   else      ok = trade.Sell(lot, p.symbol, price, sl, tp, cmt);

   PrintFormat("%s %s | Orden %s%s %s | lot=%.2f sl=%.5f tp=%.5f | %s",
               p.symbol, p.tf_name, (dir>0?"BUY":"SELL"), (strong?" (STRONG)":""), (ok?"OK":"FALLO"), lot, sl, tp,
               trade.ResultRetcodeDescription());
}

double CalcLot(string symbol, double slDistPrice)
{
   if(InpRiskPercent<=0) return InpFixedLot;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent/100.0;

   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickValue<=0) return InpFixedLot;

   double lossPerLot = (slDistPrice/tickSize) * tickValue;
   if(lossPerLot<=0) return InpFixedLot;

   double lot = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot= SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot/stepLot)*stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//====================================================================
// ESTADÍSTICAS DE RESULTADOS (P&L, Hit Rate y racha de pérdidas)
// POR PAR/TIMEFRAME, separadas en NORMAL y STRONG según el magic
// number con el que se abrió cada operación.
//====================================================================
void UpdateAllStats()
{
   for(int i=0;i<ArraySize(g_pairs);i++)
   {
      g_pairs[i].total_profit = 0; g_pairs[i].total_trades = 0;
      g_pairs[i].wins = 0; g_pairs[i].losses = 0; g_pairs[i].hit_rate = 0;
      g_pairs[i].normal_profit = 0; g_pairs[i].normal_trades = 0; g_pairs[i].normal_wins = 0; g_pairs[i].normal_hit_rate = 0;
      g_pairs[i].strong_profit = 0; g_pairs[i].strong_trades = 0; g_pairs[i].strong_wins = 0; g_pairs[i].strong_hit_rate = 0;
   }

   if(!HistorySelect(0, TimeCurrent())) return;
   int total = HistoryDealsTotal();

   // --- Paso 1: acumular P&L / trades / wins totales (orden cronológico) ---
   for(int d=0; d<total; d++)
   {
      ulong ticket = HistoryDealGetTicket(d);
      if(ticket==0) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue; // solo deals de cierre cuentan como resultado de una operación

      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket, DEAL_SWAP)
                     + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      for(int i=0;i<ArraySize(g_pairs);i++)
      {
         if(g_pairs[i].magic == magic)
         {
            g_pairs[i].total_profit += profit; g_pairs[i].total_trades++;
            g_pairs[i].normal_profit += profit; g_pairs[i].normal_trades++;
            if(profit>0) { g_pairs[i].wins++; g_pairs[i].normal_wins++; }
            else if(profit<0) g_pairs[i].losses++;
            break;
         }
         else if(g_pairs[i].magic_strong == magic)
         {
            g_pairs[i].total_profit += profit; g_pairs[i].total_trades++;
            g_pairs[i].strong_profit += profit; g_pairs[i].strong_trades++;
            if(profit>0) { g_pairs[i].wins++; g_pairs[i].strong_wins++; }
            else if(profit<0) g_pairs[i].losses++;
            break;
         }
      }
   }

   for(int i=0;i<ArraySize(g_pairs);i++)
   {
      if(g_pairs[i].total_trades>0)  g_pairs[i].hit_rate = 100.0 * g_pairs[i].wins / g_pairs[i].total_trades;
      if(g_pairs[i].normal_trades>0) g_pairs[i].normal_hit_rate = 100.0 * g_pairs[i].normal_wins / g_pairs[i].normal_trades;
      if(g_pairs[i].strong_trades>0) g_pairs[i].strong_hit_rate = 100.0 * g_pairs[i].strong_wins / g_pairs[i].strong_trades;
   }

   // --- Paso 2: racha de pérdidas consecutivas MÁS RECIENTE por par/tipo ---
   bool doneNormal[]; ArrayResize(doneNormal, ArraySize(g_pairs)); ArrayInitialize(doneNormal, false);
   bool doneStrong[]; ArrayResize(doneStrong, ArraySize(g_pairs)); ArrayInitialize(doneStrong, false);
   for(int i=0;i<ArraySize(g_pairs);i++)
   {
      g_pairs[i].consecutive_losses_normal = 0;
      g_pairs[i].consecutive_losses_strong = 0;
   }

   for(int d=total-1; d>=0; d--)
   {
      ulong ticket = HistoryDealGetTicket(d);
      if(ticket==0) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket, DEAL_SWAP)
                     + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      for(int i=0;i<ArraySize(g_pairs);i++)
      {
         if(g_pairs[i].magic == magic && !doneNormal[i])
         {
            if(profit<0) g_pairs[i].consecutive_losses_normal++;
            else doneNormal[i] = true;
            break;
         }
         else if(g_pairs[i].magic_strong == magic && !doneStrong[i])
         {
            if(profit<0) g_pairs[i].consecutive_losses_strong++;
            else doneStrong[i] = true;
            break;
         }
      }
   }
}

//====================================================================
// TABLA DE RESULTADOS EN EL JOURNAL
//====================================================================
void PrintResultsTable()
{
   UpdateAllStats();

   Print("==================== TA SUMMARY + HOPFIELD/RBM ====================");
   if(InpOnlyStrongTrades)
      Print("(Modo: SOLO se abren operaciones con señales STRONG.)");
   if(InpOnlyNormalTrades)
      Print("(Modo: SOLO se abren operaciones con señales NORMAL (Buy/Sell). Strong se muestra solo informativamente.)");
   else if(ArraySize(g_strongAllowedTFs)>0)
      PrintFormat("(Strong solo se abre en: %s. En el resto de timeframes se muestra pero no se opera.)", InpStrongAllowedTimeframes);
   if(g_tradingHalted)
      Print("*** CORTACIRCUITOS DE DRAWDOWN ACTIVO: no se abren nuevas operaciones ***");
   PrintFormat("%-10s %-5s %8s %-12s %10s %10s %-9s | %6s %9s %7s | %6s %9s %7s %4s | %6s %9s %7s %4s",
               "SYMBOL","TF","RATING","SEÑAL","H.dE","RBM.dF","CONFIRM.",
               "T.TRD","T.P&L","T.HIT%",
               "N.TRD","N.P&L","N.HIT%","N.RL",
               "S.TRD","S.P&L","S.HIT%","S.RL");
   for(int i=0;i<ArraySize(g_pairs);i++)
   {
      PairTF p = g_pairs[i];
      PrintFormat("%-10s %-5s %8.3f %-12s %10.4f %10.4f %-9s | %6d %9.2f %6.1f%% | %6d %9.2f %6.1f%% %4d | %6d %9.2f %6.1f%% %4d",
                  p.symbol, p.tf_name, p.last_rating, p.last_label,
                  p.last_hopfield_dE, p.last_rbm_dF,
                  (p.last_dir!=0 ? (p.last_confirmed?"SI":"no") : "-"),
                  p.total_trades, p.total_profit, p.hit_rate,
                  p.normal_trades, p.normal_profit, p.normal_hit_rate, p.consecutive_losses_normal,
                  p.strong_trades, p.strong_profit, p.strong_hit_rate, p.consecutive_losses_strong);
   }
   Print("(T.=Total  N.=Normal  S.=Strong  RL=Racha de pérdidas consecutivas actuales)");
   Print("---------------------------------------------------------------------");
   PrintGroupedSummary();
   Print("=====================================================================");
}

//====================================================================
// RESUMEN AGRUPADO: cómo va cada SÍMBOLO y cada TIMEFRAME globalmente,
// desglosado también en NORMAL vs STRONG.
//====================================================================
void PrintGroupedSummary()
{
   string symbols[];
   int    symTradesN[], symTradesS[]; double symProfitN[], symProfitS[]; int symWinsN[], symWinsS[];

   string tfs[];
   int    tfTradesN[], tfTradesS[]; double tfProfitN[], tfProfitS[]; int tfWinsN[], tfWinsS[];

   for(int i=0;i<ArraySize(g_pairs);i++)
   {
      PairTF p = g_pairs[i];

      int si=-1;
      for(int k=0;k<ArraySize(symbols);k++) if(symbols[k]==p.symbol) { si=k; break; }
      if(si==-1)
      {
         si = ArraySize(symbols);
         ArrayResize(symbols, si+1);
         ArrayResize(symTradesN, si+1); ArrayResize(symTradesS, si+1);
         ArrayResize(symProfitN, si+1); ArrayResize(symProfitS, si+1);
         ArrayResize(symWinsN, si+1);   ArrayResize(symWinsS, si+1);
         symbols[si]=p.symbol;
         symTradesN[si]=0; symTradesS[si]=0; symProfitN[si]=0; symProfitS[si]=0; symWinsN[si]=0; symWinsS[si]=0;
      }
      symTradesN[si]+=p.normal_trades; symProfitN[si]+=p.normal_profit; symWinsN[si]+=p.normal_wins;
      symTradesS[si]+=p.strong_trades; symProfitS[si]+=p.strong_profit; symWinsS[si]+=p.strong_wins;

      int ti=-1;
      for(int k=0;k<ArraySize(tfs);k++) if(tfs[k]==p.tf_name) { ti=k; break; }
      if(ti==-1)
      {
         ti = ArraySize(tfs);
         ArrayResize(tfs, ti+1);
         ArrayResize(tfTradesN, ti+1); ArrayResize(tfTradesS, ti+1);
         ArrayResize(tfProfitN, ti+1); ArrayResize(tfProfitS, ti+1);
         ArrayResize(tfWinsN, ti+1);   ArrayResize(tfWinsS, ti+1);
         tfs[ti]=p.tf_name;
         tfTradesN[ti]=0; tfTradesS[ti]=0; tfProfitN[ti]=0; tfProfitS[ti]=0; tfWinsN[ti]=0; tfWinsS[ti]=0;
      }
      tfTradesN[ti]+=p.normal_trades; tfProfitN[ti]+=p.normal_profit; tfWinsN[ti]+=p.normal_wins;
      tfTradesS[ti]+=p.strong_trades; tfProfitS[ti]+=p.strong_profit; tfWinsS[ti]+=p.strong_wins;
   }

   Print("-- Resumen por SÍMBOLO --");
   PrintFormat("%-10s | %6s %9s %7s | %6s %9s %7s",
               "SYMBOL", "N.TRD","N.P&L","N.HIT%", "S.TRD","S.P&L","S.HIT%");
   for(int k=0;k<ArraySize(symbols);k++)
   {
      double hrN = symTradesN[k]>0 ? 100.0*symWinsN[k]/symTradesN[k] : 0.0;
      double hrS = symTradesS[k]>0 ? 100.0*symWinsS[k]/symTradesS[k] : 0.0;
      PrintFormat("%-10s | %6d %9.2f %6.1f%% | %6d %9.2f %6.1f%%",
                  symbols[k], symTradesN[k], symProfitN[k], hrN, symTradesS[k], symProfitS[k], hrS);
   }

   Print("-- Resumen por TIMEFRAME --");
   PrintFormat("%-10s | %6s %9s %7s | %6s %9s %7s",
               "TF", "N.TRD","N.P&L","N.HIT%", "S.TRD","S.P&L","S.HIT%");
   for(int k=0;k<ArraySize(tfs);k++)
   {
      double hrN = tfTradesN[k]>0 ? 100.0*tfWinsN[k]/tfTradesN[k] : 0.0;
      double hrS = tfTradesS[k]>0 ? 100.0*tfWinsS[k]/tfTradesS[k] : 0.0;
      PrintFormat("%-10s | %6d %9.2f %6.1f%% | %6d %9.2f %6.1f%%",
                  tfs[k], tfTradesN[k], tfProfitN[k], hrN, tfTradesS[k], tfProfitS[k], hrS);
   }
}
//+------------------------------------------------------------------+