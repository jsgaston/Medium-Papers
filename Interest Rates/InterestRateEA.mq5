//+------------------------------------------------------------------+
//|                                            InterestRateEA.mq5     |
//|   EA multi-símbolo basado en decisiones de tipos de interés       |
//|   de bancos centrales, leídas de un CSV externo.                  |
//|                                                                    |
//|   Lógica: cuando una divisa sufre una subida (HIKE) de tipos y     |
//|   la otra pata del par no, se abre largo en la divisa que sube     |
//|   / corto en la que no. Para XAUUSD/XAGUSD se aplica la relación   |
//|   inversa con USD (subida de tipos USD => oro/plata a la baja).    |
//|                                                                    |
//|   Funciona en el Strategy Tester para backtesting: compara         |
//|   TimeCurrent() (tiempo simulado) contra las fechas del CSV.       |
//+------------------------------------------------------------------+
#property copyright "Javier"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- INPUTS ----------------------------------------------------------
input string InpSymbols       = "EURUSD,GBPUSD,USDJPY,USDCHF,AUDUSD,NZDUSD,USDCAD,XAUUSD"; // Símbolos a operar (separados por coma)
input string InpFileName      = "interest_rates.csv"; // Nombre del archivo CSV
input bool   InpUseCommon     = true;   // Usar carpeta Common\Files (recomendado, funciona en Tester)
input int    InpMaxAgeDays    = 5;      // Antigüedad máx. (días) de la decisión para ABRIR una operación
input int    InpHoldDays      = 10;     // Días máximos que se mantiene una posición abierta
input bool   InpCloseOnFlip   = true;   // Cerrar si la señal se invierte antes de InpHoldDays
input double InpLots          = 0.10;   // Lotaje fijo
input int    InpMagic         = 20260721;
input int    InpSlippagePts   = 30;
input bool   InpVerboseLog    = true;   // Imprimir en el Log qué está pasando
input int    InpATRPeriod     = 14;     // Periodo del ATR diario
input double InpSLAtrMult     = 1.5;    // SL = InpSLAtrMult x ATR(D1)
input double InpTPAtrMult     = 2.0;    // TP = InpTPAtrMult x ATR(D1)

//--- ESTRUCTURAS -------------------------------------------------------
struct RateEvent
  {
   datetime date;
   string   bank;
   string   currency;
   double   rate;
   double   prevRate;
   string   action;   // HIKE, CUT, HOLD
  };

RateEvent   g_events[];
string      g_symbols[];
int         g_atrHandles[];
datetime    g_lastBarProcessed = 0;
datetime    g_fileLastLoad     = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);

   int n = StringSplit(InpSymbols, ',', g_symbols);
   if(n <= 0)
     {
      Print("InterestRateEA: no se ha podido interpretar InpSymbols");
      return(INIT_PARAMETERS_INCORRECT);
     }
   ArrayResize(g_atrHandles, n);
   for(int i = 0; i < n; i++)
     {
      StringTrimLeft(g_symbols[i]);
      StringTrimRight(g_symbols[i]);
      if(!SymbolSelect(g_symbols[i], true))
         Print("InterestRateEA: aviso, no se pudo añadir ", g_symbols[i], " al Market Watch");

      g_atrHandles[i] = iATR(g_symbols[i], PERIOD_D1, InpATRPeriod);
      if(g_atrHandles[i] == INVALID_HANDLE)
         Print("InterestRateEA: aviso, no se pudo crear ATR para ", g_symbols[i]);
     }

   if(!LoadRatesFile())
     {
      Print("InterestRateEA: no se pudo cargar ", InpFileName, " (¿ruta correcta / Common\\Files?)");
      // no abortamos el init: puede que el archivo se cree/copie después
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   for(int i = 0; i < ArraySize(g_atrHandles); i++)
      if(g_atrHandles[i] != INVALID_HANDLE)
         IndicatorRelease(g_atrHandles[i]);
  }

//+------------------------------------------------------------------+
//| Carga / recarga el CSV de decisiones de tipos                     |
//+------------------------------------------------------------------+
bool LoadRatesFile()
  {
   int flags = FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ;
   if(InpUseCommon) flags |= FILE_COMMON;

   int fh = FileOpen(InpFileName, flags, ',');
   if(fh == INVALID_HANDLE)
      return(false);

   ArrayResize(g_events, 0);
   int count = 0;

   while(!FileIsEnding(fh))
     {
      string sDate   = FileReadString(fh);
      if(sDate == "") break;
      string sBank   = FileReadString(fh);
      string sCcy    = FileReadString(fh);
      string sRate   = FileReadString(fh);
      string sPrev   = FileReadString(fh);
      string sAction = FileReadString(fh);

      // saltar cabecera
      if(sDate == "Date" || sDate == "date")
         continue;

      datetime d = StringToTime(sDate); // admite "yyyy.mm.dd"
      if(d == 0) continue;

      int idx = count;
      ArrayResize(g_events, count + 1);
      g_events[idx].date     = d;
      g_events[idx].bank     = sBank;
      g_events[idx].currency = sCcy;
      g_events[idx].rate     = StringToDouble(sRate);
      g_events[idx].prevRate = StringToDouble(sPrev);
      g_events[idx].action   = sAction;
      count++;
     }
   FileClose(fh);

   if(InpVerboseLog)
      PrintFormat("InterestRateEA: cargados %d eventos de %s", count, InpFileName);

   return(count > 0);
  }

//+------------------------------------------------------------------+
//| Devuelve el sesgo (+1 HIKE, -1 CUT, 0 HOLD/ninguno) de una divisa  |
//| y la antigüedad en días del evento más reciente <= asOf            |
//+------------------------------------------------------------------+
int GetCurrencyBias(const string currency, const datetime asOf, int &ageDaysOut)
  {
   int      bestScore = 0;
   datetime bestDate   = 0;
   ageDaysOut = -1;

   for(int i = 0; i < ArraySize(g_events); i++)
     {
      if(g_events[i].currency != currency) continue;
      if(g_events[i].date > asOf) continue;          // no usar eventos "futuros" (clave para backtest)
      if(g_events[i].date <= bestDate) continue;      // nos quedamos con el más reciente

      bestDate = g_events[i].date;
      if(g_events[i].action == "HIKE")      bestScore = 1;
      else if(g_events[i].action == "CUT")  bestScore = -1;
      else                                   bestScore = 0;
     }

   if(bestDate > 0)
      ageDaysOut = (int)((asOf - bestDate) / 86400);

   return(bestScore);
  }

//+------------------------------------------------------------------+
//| Extrae base/quote de un símbolo de 6 letras (limpia sufijos)      |
//+------------------------------------------------------------------+
bool GetBaseQuote(const string symbol, string &base, string &quote)
  {
   string s = symbol;
   if(StringLen(s) < 6) return(false);
   base  = StringSubstr(s, 0, 3);
   quote = StringSubstr(s, 3, 3);
   return(true);
  }

//+------------------------------------------------------------------+
//| Calcula la señal neta de un símbolo: +1 comprar, -1 vender, 0 nada |
//| ageDaysOut = antigüedad del evento disparador más reciente         |
//+------------------------------------------------------------------+
int GetSymbolSignal(const string symbol, const datetime asOf, int &ageDaysOut)
  {
   ageDaysOut = 999;

   if(StringFind(symbol, "XAU") == 0 || StringFind(symbol, "XAG") == 0)
     {
      int ageUSD;
      int usdBias = GetCurrencyBias("USD", asOf, ageUSD);
      ageDaysOut = ageUSD;
      return(-usdBias); // USD sube tipos => oro/plata bajan
     }

   string base, quote;
   if(!GetBaseQuote(symbol, base, quote))
      return(0);

   int ageBase, ageQuote;
   int baseBias  = GetCurrencyBias(base,  asOf, ageBase);
   int quoteBias = GetCurrencyBias(quote, asOf, ageQuote);

   int net = baseBias - quoteBias;
   if(net == 0) return(0);

   // antigüedad = la del evento más reciente entre los dos que forman el par
   if(ageBase  >= 0) ageDaysOut = MathMin(ageDaysOut, ageBase);
   if(ageQuote >= 0) ageDaysOut = MathMin(ageDaysOut, ageQuote);

   if(net > 0) return(1);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Devuelve el ATR diario (última barra cerrada) de un símbolo        |
//+------------------------------------------------------------------+
double GetATR(const string symbol)
  {
   for(int i = 0; i < ArraySize(g_symbols); i++)
     {
      if(g_symbols[i] != symbol) continue;
      if(g_atrHandles[i] == INVALID_HANDLE) return(0.0);

      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(g_atrHandles[i], 0, 1, 1, buf) <= 0)
         return(0.0);
      return(buf[0]);
     }
   return(0.0);
  }

//+------------------------------------------------------------------+
//| Busca posición abierta de este EA para un símbolo                 |
//+------------------------------------------------------------------+
bool GetOpenPosition(const string symbol, ulong &ticket, long &type, datetime &openTime)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ticket   = t;
      type     = PositionGetInteger(POSITION_TYPE);
      openTime = (datetime)PositionGetInteger(POSITION_TIME);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Gestiona una posición ya abierta: cierre por tiempo o por giro     |
//+------------------------------------------------------------------+
void ManagePosition(const string symbol, const datetime now)
  {
   ulong    ticket;
   long     type;
   datetime openTime;
   if(!GetOpenPosition(symbol, ticket, type, openTime))
      return;

   int ageDays = (int)((now - openTime) / 86400);

   if(ageDays >= InpHoldDays)
     {
      if(InpVerboseLog) PrintFormat("%s: cerrando por tiempo (%d días)", symbol, ageDays);
      trade.PositionClose(symbol);
      return;
     }

   if(InpCloseOnFlip)
     {
      int ageSignal;
      int signal = GetSymbolSignal(symbol, now, ageSignal);
      bool isLong = (type == POSITION_TYPE_BUY);
      if((isLong && signal < 0) || (!isLong && signal > 0))
        {
         if(InpVerboseLog) PrintFormat("%s: cerrando por señal contraria", symbol);
         trade.PositionClose(symbol);
        }
     }
  }

//+------------------------------------------------------------------+
//| Abre una posición nueva si procede                                 |
//+------------------------------------------------------------------+
void CheckForNewSignal(const string symbol, const datetime now)
  {
   ulong    ticket;
   long     type;
   datetime openTime;
   if(GetOpenPosition(symbol, ticket, type, openTime))
      return; // ya hay posición abierta, no dupliques

   int ageDays;
   int signal = GetSymbolSignal(symbol, now, ageDays);
   if(signal == 0) return;
   if(ageDays > InpMaxAgeDays) return; // el evento ya no es "fresco"

   if(!SymbolSelect(symbol, true)) return;

   if(!IsSymbolTradable(symbol, now))
     {
      if(InpVerboseLog)
         PrintFormat("%s: sin sesión/cotización válida en %s, se omite (señal=%d)", symbol, TimeToString(now), signal);
      return;
     }

   double price;
   bool ok;
   double sl = 0.0, tp = 0.0;
   double atr = GetATR(symbol);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minStopDist = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

   if(signal > 0)
     {
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(atr > 0)
        {
         double slDist = MathMax(InpSLAtrMult * atr, minStopDist);
         double tpDist = MathMax(InpTPAtrMult * atr, minStopDist);
         sl = NormalizeDouble(price - slDist, digits);
         tp = NormalizeDouble(price + tpDist, digits);
        }
      ok = trade.Buy(InpLots, symbol, price, sl, tp, "IR-EA hike/cut diff");
     }
   else
     {
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
      if(atr > 0)
        {
         double slDist = MathMax(InpSLAtrMult * atr, minStopDist);
         double tpDist = MathMax(InpTPAtrMult * atr, minStopDist);
         sl = NormalizeDouble(price + slDist, digits);
         tp = NormalizeDouble(price - tpDist, digits);
        }
      ok = trade.Sell(InpLots, symbol, price, sl, tp, "IR-EA hike/cut diff");
     }

   if(InpVerboseLog)
     {
      if(ok)
         PrintFormat("%s: ABIERTO señal=%d antigüedad=%d días SL=%s TP=%s (ATR=%s)",
                     symbol, signal, ageDays, DoubleToString(sl, digits), DoubleToString(tp, digits),
                     atr > 0 ? DoubleToString(atr, digits) : "n/d");
      else
         PrintFormat("%s: FALLO al abrir señal=%d antigüedad=%d días -> retcode=%d (%s)",
                     symbol, signal, ageDays, trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Comprueba que el símbolo tiene sesión de trading activa y una     |
//| cotización reciente antes de intentar abrir. Evita el error       |
//| "Market closed" (132) que aparece al operar sin datos cargados.   |
//+------------------------------------------------------------------+
bool IsSymbolTradable(const string symbol, const datetime now)
  {
   long tradeMode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return(false);

   // ¿Hay sesión de cotización/trading abierta para esta hora del servidor?
   MqlDateTime dt;
   TimeToStruct(now, dt);
   datetime from, to;
   if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, 0, from, to))
      return(false); // no hay sesión definida ese día (fin de semana, festivo del bróker, etc.)

   // Cotización: debe existir y no estar obsoleta (evita el hueco de datos
   // al principio del rango de backtest, cuando el símbolo aún no tiene histórico)
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return(false);
   if(tick.ask <= 0 || tick.bid <= 0)
      return(false);
   if((now - tick.time) > 3 * 86400) // más de 3 días sin cotización = sin datos reales aquí
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Recargar el CSV una sola vez por día (no hace falta más a menudo)
   datetime barTime = iTime(_Symbol, PERIOD_D1, 0);
   if(barTime != g_lastBarProcessed)
     {
      g_lastBarProcessed = barTime;
      LoadRatesFile(); // recarga por si el archivo se ha actualizado (manual o por el script Python)
     }

   // Pero la gestión de posiciones y la búsqueda de señal se evalúan en
   // CADA tick, para reintentar si el primer intento del día cae justo en
   // la ventana de "Market closed" (rollover de medianoche). GetOpenPosition
   // evita que se abra más de una vez la misma señal.
   datetime now = TimeCurrent();

   for(int i = 0; i < ArraySize(g_symbols); i++)
     {
      string symbol = g_symbols[i];
      if(symbol == "") continue;

      ManagePosition(symbol, now);
      CheckForNewSignal(symbol, now);
     }
  }
//+------------------------------------------------------------------+
