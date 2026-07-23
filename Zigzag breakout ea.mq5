//+------------------------------------------------------------------+
//|                                         ZigZag_Breakout_EA.mq5    |
//|  EA basado en el enfoque "ZigZag swing breakout" descrito en un  |
//|  artículo de backtest (ETH-USD, Backtrader). Reconstruido y      |
//|  mejorado para MT5 por Claude para Javier Santiago.               |
//|                                                                    |
//|  Lógica base (según el artículo):                                 |
//|   - Detecta swing highs / swing lows con ZigZag                   |
//|   - Entra en ruptura del último swing confirmado                  |
//|   - Confirma con volumen                                          |
//|   - Usa trailing stop                                             |
//|                                                                    |
//|  Mejoras añadidas respecto al artículo original:                  |
//|   1. Filtro de tendencia en timeframe superior (evita operar      |
//|      contra-tendencia, el artículo solo usaba 1 timeframe)        |
//|   2. SL/TP/trailing basados en ATR dinámico (no fijo) -> se       |
//|      adapta a la volatilidad real del activo                      |
//|   3. Position sizing por % de riesgo de la cuenta, no lote fijo   |
//|   4. Filtro de "fuerza de swing" mínima (evita ruido en ZigZag)   |
//|   5. Cooldown tras SL para evitar overtrading en rango             |
//|   6. Logging a CSV de cada operación (equity, motivo, R multiple) |
//+------------------------------------------------------------------+
#property copyright "Javier Santiago Gastón de Iriarte Cabrera"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//================== INPUTS ==================
input group "=== ZigZag ==="
input int      InpZZDepth        = 12;      // ZigZag Depth
input int      InpZZDeviation    = 5;       // ZigZag Deviation
input int      InpZZBackstep     = 3;       // ZigZag Backstep
input double   InpMinSwingATR    = 1.0;     // Fuerza mínima del swing en múltiplos de ATR (filtra ruido)

input group "=== Filtro de tendencia (mejora) ==="
input bool     InpUseHTFFilter   = true;    // Usar filtro de tendencia en timeframe superior
input ENUM_TIMEFRAMES InpHTF     = PERIOD_H4; // Timeframe superior para el filtro
input int      InpHTFEmaPeriod   = 50;      // Periodo de EMA en el timeframe superior

input group "=== Volumen ==="
input bool     InpUseVolumeFilter= true;    // Exigir volumen por encima de la media
input int      InpVolMAPeriod    = 20;      // Periodo de media de volumen
input double   InpVolMultiplier  = 1.1;     // Volumen actual debe ser >= media * este factor

input group "=== Riesgo y gestión de posición ==="
input double   InpRiskPercent    = 1.0;     // % de la cuenta arriesgado por operación
input int      InpATRPeriod      = 14;      // Periodo ATR
input double   InpSLAtrMult      = 1.5;     // Stop Loss = ATR * este múltiplo
input double   InpTPAtrMult      = 3.0;     // Take Profit = ATR * este múltiplo (R:R ~2:1)
input bool     InpUseTrailing    = true;    // Activar trailing stop
input double   InpTrailAtrMult   = 1.2;     // Trailing stop = ATR * este múltiplo
input double   InpTrailStepAtr   = 0.2;     // Paso mínimo (en ATR) para mover el trailing

input group "=== Filtros anti-overtrading (mejora) ==="
input int      InpCooldownBarsAfterSL = 3;  // Barras de espera tras un Stop Loss
input int      InpMagic          = 20260723;
input string   InpTradeComment   = "ZigZagBreakoutEA";
input bool     InpOneTradeAtATime= true;

//================== HANDLES / GLOBALES ==================
int hZigZag, hATR, hVolMA, hHTF_EMA;
datetime lastBarTime = 0;
int barsSinceSL = 999;
double lastSwingHigh = 0, lastSwingLow = 0;
string csvFileName;

//+------------------------------------------------------------------+
int OnInit()
  {
   hZigZag = iCustom(_Symbol, _Period, "Examples\\ZigZag", InpZZDepth, InpZZDeviation, InpZZBackstep);
   if(hZigZag == INVALID_HANDLE)
     {
      Print("Error creando handle ZigZag: ", GetLastError());
      return(INIT_FAILED);
     }

   hATR = iATR(_Symbol, _Period, InpATRPeriod);
   hVolMA = iMA(_Symbol, _Period, InpVolMAPeriod, 0, MODE_SMA, VOLUME_TICK);
   if(InpUseHTFFilter)
      hHTF_EMA = iMA(_Symbol, InpHTF, InpHTFEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);

   csvFileName = "ZigZagBreakoutEA_" + _Symbol + "_trades.csv";
   if(!FileIsExist(csvFileName))
     {
      int f = FileOpen(csvFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(f != INVALID_HANDLE)
        {
         FileWrite(f, "time", "symbol", "type", "entry", "sl", "tp", "lots", "reason", "equity");
         FileClose(f);
        }
     }

   Print("ZigZag_Breakout_EA inicializado en ", _Symbol, " ", EnumToString(_Period));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hZigZag != INVALID_HANDLE) IndicatorRelease(hZigZag);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hVolMA != INVALID_HANDLE) IndicatorRelease(hVolMA);
   if(InpUseHTFFilter && hHTF_EMA != INVALID_HANDLE) IndicatorRelease(hHTF_EMA);
  }

//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(hATR, 0, 0, 1, buf) <= 0) return 0;
   return buf[0];
  }

//+------------------------------------------------------------------+
// Recorre el buffer ZigZag y devuelve el último swing high y low
// confirmados (distintos de 0), filtrando los que no superan
// InpMinSwingATR * ATR de diferencia con el swing anterior.
//+------------------------------------------------------------------+
bool GetLastSwings(double &swingHigh, double &swingLow, datetime &swingHighTime, datetime &swingLowTime)
  {
   int lookback = 300;
   double zz[];
   ArraySetAsSeries(zz, true);
   if(CopyBuffer(hZigZag, 0, 0, lookback, zz) <= 0) return false;

   double atr = GetATR();
   if(atr <= 0) return false;

   swingHigh = 0; swingLow = 0;
   swingHighTime = 0; swingLowTime = 0;
   double prevSwing = 0;

   for(int i = 0; i < lookback; i++)
     {
      if(zz[i] == 0) continue;

      if(prevSwing != 0 && MathAbs(zz[i] - prevSwing) < InpMinSwingATR * atr)
         continue; // swing demasiado pequeño, ruido

      // Determinar si es high o low comparando con el precio de cierre en ese punto
      double high_i = iHigh(_Symbol, _Period, i);
      double low_i  = iLow(_Symbol, _Period, i);

      if(MathAbs(zz[i] - high_i) < _Point*2 && swingHigh == 0)
        {
         swingHigh = zz[i];
         swingHighTime = iTime(_Symbol, _Period, i);
        }
      else if(MathAbs(zz[i] - low_i) < _Point*2 && swingLow == 0)
        {
         swingLow = zz[i];
         swingLowTime = iTime(_Symbol, _Period, i);
        }

      prevSwing = zz[i];
      if(swingHigh != 0 && swingLow != 0) break;
     }

   return (swingHigh != 0 && swingLow != 0);
  }

//+------------------------------------------------------------------+
bool VolumeConfirmed()
  {
   if(!InpUseVolumeFilter) return true;
   double volMA[]; ArraySetAsSeries(volMA, true);
   if(CopyBuffer(hVolMA, 0, 1, 1, volMA) <= 0) return false;
   long curVol = iVolume(_Symbol, _Period, 1);
   return (curVol >= volMA[0] * InpVolMultiplier);
  }

//+------------------------------------------------------------------+
int HTFTrend()
  {
   // 1 = alcista, -1 = bajista, 0 = sin filtro / indeterminado
   if(!InpUseHTFFilter) return 0;
   double ema[]; ArraySetAsSeries(ema, true);
   if(CopyBuffer(hHTF_EMA, 0, 0, 2, ema) <= 0) return 0;
   double closeHTF = iClose(_Symbol, InpHTF, 0);
   if(closeHTF > ema[0]) return 1;
   if(closeHTF < ema[0]) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
double CalcLotSize(double slDistance)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0 || tickValue <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lots = riskMoney / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
  }

//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagic)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
void LogTrade(string type, double entry, double sl, double tp, double lots, string reason)
  {
   int f = FileOpen(csvFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(f == INVALID_HANDLE) return;
   FileSeek(f, 0, SEEK_END);
   FileWrite(f, TimeToString(TimeCurrent()), _Symbol, type,
              DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
              DoubleToString(tp, _Digits), DoubleToString(lots, 2), reason,
              DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   FileClose(f);
  }

//+------------------------------------------------------------------+
void ManageTrailing()
  {
   if(!InpUseTrailing) return;
   double atr = GetATR();
   if(atr <= 0) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);
      double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                   : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double newSL;
      if(type == POSITION_TYPE_BUY)
        {
         newSL = price - InpTrailAtrMult * atr;
         if(newSL > curSL + InpTrailStepAtr * atr)
            trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
        }
      else
        {
         newSL = price + InpTrailAtrMult * atr;
         if(curSL == 0 || newSL < curSL - InpTrailStepAtr * atr)
            trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
        }
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Trailing se gestiona en cada tick
   ManageTrailing();

   // El resto de la lógica (entradas) solo en apertura de vela nueva
   datetime curBarTime = iTime(_Symbol, _Period, 0);
   if(curBarTime == lastBarTime) return;

   bool newBar = (lastBarTime != 0);
   lastBarTime = curBarTime;
   if(!newBar) return;

   barsSinceSL++;

   if(InpOneTradeAtATime && HasOpenPosition()) return;
   if(barsSinceSL < InpCooldownBarsAfterSL) return;

   double swingHigh, swingLow;
   datetime tHigh, tLow;
   if(!GetLastSwings(swingHigh, swingLow, tHigh, tLow)) return;

   double atr = GetATR();
   if(atr <= 0) return;

   double closePrev = iClose(_Symbol, _Period, 1);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   int trend = HTFTrend();

   // --- Señal de compra: ruptura del último swing high ---
   if(closePrev > swingHigh && (trend >= 0) && VolumeConfirmed())
     {
      double sl = ask - InpSLAtrMult * atr;
      double tp = ask + InpTPAtrMult * atr;
      double lots = CalcLotSize(ask - sl);
      if(trade.Buy(lots, _Symbol, ask, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), InpTradeComment))
         LogTrade("BUY", ask, sl, tp, lots, "Breakout swing high");
      return;
     }

   // --- Señal de venta: ruptura del último swing low ---
   if(closePrev < swingLow && (trend <= 0) && VolumeConfirmed())
     {
      double sl = bid + InpSLAtrMult * atr;
      double tp = bid - InpTPAtrMult * atr;
      double lots = CalcLotSize(sl - bid);
      if(trade.Sell(lots, _Symbol, bid, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), InpTradeComment))
         LogTrade("SELL", bid, sl, tp, lots, "Breakout swing low");
      return;
     }
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      if(HistoryDealSelect(trans.deal))
        {
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
         if(magic == InpMagic && reason == DEAL_REASON_SL)
            barsSinceSL = 0;
        }
     }
  }
//+------------------------------------------------------------------+