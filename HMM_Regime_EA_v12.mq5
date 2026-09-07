//+------------------------------------------------------------------+
//|                                            HMM_Regime_EA_v12.mq5 |
//|  HMM de regimenes autoentrenado + modulo de reversion por         |
//|  cruce del estocastico con volumen superior a la media.           |
//|                                                                   |
//|  El modulo estocastico esta delimitado entre las marcas           |
//|  //<<< MODULO STOCH+VOLUMEN >>>  y  //<<< FIN MODULO >>>          |
//|  para poder trasplantarlo a otro EA sin arrastrar el HMM.         |
//+------------------------------------------------------------------+
#property copyright "Javier"
#property version   "1.20"
#property description "HMM + reversion estocastico/volumen con validacion automatica"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//==================================================================
//  MODOS DE ENTRADA
//==================================================================
enum ENUM_ENTRY_MODE
{
   ENTRY_HMM_ONLY,      // Solo HMM
   ENTRY_STOCH_ONLY,    // Solo reversion estocastico+volumen
   ENTRY_STOCH_FILTER,  // Reversion, pero solo si el HMM no la contradice
   ENTRY_ANY            // Cualquiera de las dos
};

//==================================================================
//  PARAMETROS
//==================================================================
input group "=== Estrategia ==="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_STOCH_FILTER; // Modo de entrada

input group "=== Reversion: estocastico + volumen ==="
input int      InpStochK        = 5;        // %K
input int      InpStochD        = 3;        // %D
input int      InpStochSlow     = 3;        // Slowing
input double   InpOversold      = 25.0;     // Zona de sobreventa (cruce alcista)
input double   InpOverbought    = 75.0;     // Zona de sobrecompra (cruce bajista)
input bool     InpRequireZone   = true;     // Exigir que el cruce ocurra en zona
input int      InpVolLookback   = 10;       // Barras para la media de volumen
input double   InpVolFactor     = 1.5;      // Volumen minimo (x media)
input bool     InpUseRealVolume = false;    // Volumen real (si el broker lo da)
input int      InpStochHold     = 6;        // Barras de medicion del edge
input bool     InpStochExit     = true;     // Cerrar si aparece reversion contraria

input group "=== Modelo HMM ==="
input int      InpStates        = 3;        // Estados ocultos
input int      InpReturnHorizon = 5;        // K: barras del retorno acumulado
input int      InpTrainBars     = 2500;     // Barras de entrenamiento
input int      InpRetrainBars   = 250;      // Reentrenar cada N barras
input int      InpMaxIter       = 200;      // Iteraciones EM
input double   InpTol           = 1e-7;     // Tolerancia
input int      InpRestarts      = 6;        // Reinicios aleatorios
input double   InpValidFrac     = 0.25;     // Fraccion de validacion
input int      InpSeed          = 0;        // Semilla (0 = aleatoria)
input double   InpVarFloor      = 1e-4;     // Suelo de varianza
input int      InpFilterBars    = 400;      // Ventana del filtro forward

input group "=== Senal HMM ==="
input double   InpMinProb       = 0.55;     // Prob. minima a favor
input double   InpMinEdgeATR    = 0.25;     // Edge minimo (x ATR)
input double   InpMaxHorizon    = 20.0;     // Tope del horizonte h

input group "=== Validacion automatica ==="
input bool     InpRequireValid  = true;     // Exigir edge out-of-sample
input int      InpMinValSignals = 20;       // Senales minimas
input double   InpMinValEdgeBp  = 0.0;      // Edge minimo (pb)

input group "=== Riesgo ==="
input double   InpRiskPercent   = 0.5;      // Riesgo por operacion (%)
input double   InpFixedLot      = 0.0;      // Lote fijo (>0 ignora riesgo)
input double   InpSL_ATR        = 2.0;      // Stop loss (x ATR)
input double   InpTP_ATR        = 3.0;      // Take profit (x ATR, 0 = sin TP)
input bool     InpUseTrailing   = true;     // Trailing stop
input double   InpTrail_ATR     = 1.5;      // Trailing (x ATR)
input int      InpATRPeriod     = 14;       // Periodo ATR
input int      InpMaxSpreadPts  = 40;       // Spread maximo (puntos)
input int      InpSlippagePts   = 30;       // Desviacion maxima (puntos)

input group "=== General ==="
input bool     InpCloseOnFlip   = true;     // Cerrar al invertirse la senal
input bool     InpReverse       = true;     // Reabrir en sentido contrario
input long     InpMagic         = 20260907; // Magic number
input string   InpComentario    = "HMM+STO";// Comentario
input bool     InpGuardarModelo = true;     // Persistir el modelo
input bool     InpPanel         = true;     // Panel en el grafico
input bool     InpDebug         = true;     // Log de diagnostico

#define DIMS 2
#define MODEL_VERSION 2
#define PARKINSON 0.6006

//==================================================================
//  CLASE HMM
//==================================================================
class CHMM
{
public:
   int      N, D, K;
   double   pi[], A[], mu[], var[], fMean[], fStd[];
   bool     trained, tradable;
   double   trainLL, validLL, valEdgeBp;
   int      valSignals;
   datetime lastTrain;

            CHMM(void){ N=0;D=0;K=1;trained=false;tradable=false;
                        trainLL=0;validLL=0;valEdgeBp=0;valSignals=0;lastTrain=0; }

   void     Allocate(const int n,const int d);
   void     CopyFrom(const CHMM &src);
   void     RandomInit(const double &x[],const int T);
   void     ComputeB(const double &x[],const int T,double &B[],double &off[]) const;
   double   Forward(const double &B[],const double &off[],const int T,double &alpha[],double &c[]) const;
   void     Backward(const double &B[],const int T,const double &c[],double &beta[]) const;
   double   EM(const double &x[],const int T,const int maxIter,const double tol);
   double   LogLik(const double &x[],const int T) const;
   bool     FilterAll(const double &x[],const int T,double &alpha[]) const;
   bool     Sane(void) const;
   bool     Save(const string file) const;
   bool     Load(const string file);
};

void CHMM::Allocate(const int n,const int d)
{
   N=n; D=d;
   ArrayResize(pi,N); ArrayResize(A,N*N);
   ArrayResize(mu,N*D); ArrayResize(var,N*D);
   ArrayResize(fMean,D); ArrayResize(fStd,D);
   ArrayInitialize(fMean,0.0); ArrayInitialize(fStd,1.0);
}

void CHMM::CopyFrom(const CHMM &src)
{
   Allocate(src.N,src.D);
   K=src.K;
   ArrayCopy(pi,src.pi); ArrayCopy(A,src.A);
   ArrayCopy(mu,src.mu); ArrayCopy(var,src.var);
   ArrayCopy(fMean,src.fMean); ArrayCopy(fStd,src.fStd);
   trained=src.trained; tradable=src.tradable;
   trainLL=src.trainLL; validLL=src.validLL;
   valEdgeBp=src.valEdgeBp; valSignals=src.valSignals;
   lastTrain=src.lastTrain;
}

void CHMM::RandomInit(const double &x[],const int T)
{
   double gm[],gv[];
   ArrayResize(gm,D); ArrayResize(gv,D);
   for(int d=0; d<D; d++)
   {
      double s=0.0,s2=0.0;
      for(int t=0; t<T; t++){ double v=x[t*D+d]; s+=v; s2+=v*v; }
      gm[d]=s/T;
      gv[d]=MathMax(s2/T-gm[d]*gm[d],InpVarFloor);
   }
   for(int i=0; i<N; i++)
   {
      pi[i]=1.0/N;
      double row=0.0;
      for(int j=0; j<N; j++)
      {
         double base=(i==j)?0.85:(0.15/MathMax(1,N-1));
         A[i*N+j]=base*(0.7+0.6*(MathRand()/32767.0));
         row+=A[i*N+j];
      }
      for(int j=0; j<N; j++) A[i*N+j]/=row;
      int t0=(int)(MathRand()%T);
      for(int d=0; d<D; d++)
      {
         mu[i*D+d]=0.6*x[t0*D+d]+0.4*gm[d];
         var[i*D+d]=gv[d]*(0.5+MathRand()/32767.0);
      }
   }
}

void CHMM::ComputeB(const double &x[],const int T,double &B[],double &off[]) const
{
   ArrayResize(B,T*N); ArrayResize(off,T);
   double lb[]; ArrayResize(lb,N);
   for(int t=0; t<T; t++)
   {
      double mx=-DBL_MAX;
      for(int i=0; i<N; i++)
      {
         double s=0.0;
         for(int d=0; d<D; d++)
         {
            double v=MathMax(var[i*D+d],InpVarFloor);
            double z=x[t*D+d]-mu[i*D+d];
            s+=-0.5*(MathLog(2.0*M_PI*v)+z*z/v);
         }
         lb[i]=s;
         if(s>mx) mx=s;
      }
      off[t]=mx;
      for(int i=0; i<N; i++) B[t*N+i]=MathExp(lb[i]-mx);
   }
}

double CHMM::Forward(const double &B[],const double &off[],const int T,double &alpha[],double &c[]) const
{
   ArrayResize(alpha,T*N); ArrayResize(c,T);
   double LL=0.0;
   for(int t=0; t<T; t++)
   {
      double sum=0.0;
      if(t==0){ for(int i=0;i<N;i++){ alpha[i]=pi[i]*B[i]; sum+=alpha[i]; } }
      else
      {
         for(int j=0; j<N; j++)
         {
            double acc=0.0;
            for(int i=0; i<N; i++) acc+=alpha[(t-1)*N+i]*A[i*N+j];
            alpha[t*N+j]=acc*B[t*N+j];
            sum+=alpha[t*N+j];
         }
      }
      if(sum<1e-300) sum=1e-300;
      c[t]=sum;
      for(int i=0; i<N; i++) alpha[t*N+i]/=sum;
      LL+=MathLog(sum)+off[t];
   }
   return LL;
}

void CHMM::Backward(const double &B[],const int T,const double &c[],double &beta[]) const
{
   ArrayResize(beta,T*N);
   for(int i=0; i<N; i++) beta[(T-1)*N+i]=1.0;
   for(int t=T-2; t>=0; t--)
      for(int i=0; i<N; i++)
      {
         double acc=0.0;
         for(int j=0; j<N; j++) acc+=A[i*N+j]*B[(t+1)*N+j]*beta[(t+1)*N+j];
         beta[t*N+i]=acc/c[t+1];
      }
}

double CHMM::EM(const double &x[],const int T,const int maxIter,const double tol)
{
   double B[],off[],alpha[],c[],beta[];
   double prevLL=-DBL_MAX,LL=-DBL_MAX;
   double gsum[],gsumT1[],xisum[],sx[],sx2[],g0[],g[],xi[];
   ArrayResize(gsum,N); ArrayResize(gsumT1,N); ArrayResize(xisum,N*N);
   ArrayResize(sx,N*D); ArrayResize(sx2,N*D); ArrayResize(g0,N);
   ArrayResize(g,N); ArrayResize(xi,N*N);

   for(int iter=0; iter<maxIter; iter++)
   {
      ComputeB(x,T,B,off);
      LL=Forward(B,off,T,alpha,c);
      Backward(B,T,c,beta);

      ArrayInitialize(gsum,0.0);  ArrayInitialize(gsumT1,0.0);
      ArrayInitialize(xisum,0.0); ArrayInitialize(sx,0.0);
      ArrayInitialize(sx2,0.0);   ArrayInitialize(g0,0.0);

      for(int t=0; t<T; t++)
      {
         double tot=0.0;
         for(int i=0; i<N; i++){ g[i]=alpha[t*N+i]*beta[t*N+i]; tot+=g[i]; }
         if(tot<=0.0){ for(int i=0;i<N;i++) g[i]=1.0/N; }
         else        { for(int i=0;i<N;i++) g[i]/=tot; }
         if(t==0) for(int i=0; i<N; i++) g0[i]=g[i];

         for(int i=0; i<N; i++)
         {
            gsum[i]+=g[i];
            for(int d=0; d<D; d++)
            {
               double v=x[t*D+d];
               sx[i*D+d]+=g[i]*v;
               sx2[i*D+d]+=g[i]*v*v;
            }
         }
         if(t<T-1)
         {
            double tot2=0.0;
            for(int i=0; i<N; i++)
               for(int j=0; j<N; j++)
               {
                  double val=alpha[t*N+i]*A[i*N+j]*B[(t+1)*N+j]*beta[(t+1)*N+j];
                  xi[i*N+j]=val; tot2+=val;
               }
            if(tot2<=0.0) for(int k=0;k<N*N;k++) xi[k]=1.0/(N*N);
            else          for(int k=0;k<N*N;k++) xi[k]/=tot2;
            for(int k=0; k<N*N; k++) xisum[k]+=xi[k];
            for(int i=0; i<N; i++) gsumT1[i]+=g[i];
         }
      }

      double s0=0.0;
      for(int i=0; i<N; i++) s0+=g0[i];
      for(int i=0; i<N; i++) pi[i]=(s0>0.0)?g0[i]/s0:1.0/N;

      for(int i=0; i<N; i++)
      {
         double den=gsumT1[i];
         if(den<=1e-12){ for(int j=0;j<N;j++) A[i*N+j]=1.0/N; }
         else
         {
            double row=0.0;
            for(int j=0; j<N; j++){ A[i*N+j]=xisum[i*N+j]/den; row+=A[i*N+j]; }
            if(row>0.0) for(int j=0;j<N;j++) A[i*N+j]/=row;
            else        for(int j=0;j<N;j++) A[i*N+j]=1.0/N;
         }
         double dg=MathMax(gsum[i],1e-12);
         for(int d=0; d<D; d++)
         {
            double m=sx[i*D+d]/dg;
            double v=sx2[i*D+d]/dg-m*m;
            mu[i*D+d]=m;
            var[i*D+d]=MathMax(v,InpVarFloor);
         }
      }
      if(iter>0 && MathAbs(LL-prevLL)<tol*MathAbs(prevLL)) break;
      prevLL=LL;
   }
   trainLL=LL;
   return LL;
}

double CHMM::LogLik(const double &x[],const int T) const
{
   double B[],off[],alpha[],c[];
   ComputeB(x,T,B,off);
   return Forward(B,off,T,alpha,c);
}

bool CHMM::FilterAll(const double &x[],const int T,double &alpha[]) const
{
   if(N<2||T<2) return false;
   double B[],off[],c[];
   ComputeB(x,T,B,off);
   Forward(B,off,T,alpha,c);
   return true;
}

bool CHMM::Sane(void) const
{
   if(N<2||D<1) return false;
   for(int i=0;i<N*D;i++)
      if(!MathIsValidNumber(mu[i])||!MathIsValidNumber(var[i])||var[i]<=0.0) return false;
   for(int i=0;i<N*N;i++)
      if(!MathIsValidNumber(A[i])||A[i]<0.0) return false;
   for(int d=0;d<D;d++)
      if(fStd[d]<=0.0||!MathIsValidNumber(fMean[d])) return false;
   return true;
}

bool CHMM::Save(const string file) const
{
   int h=FileOpen(file,FILE_WRITE|FILE_BIN);
   if(h==INVALID_HANDLE) return false;
   FileWriteInteger(h,MODEL_VERSION,INT_VALUE);
   FileWriteInteger(h,N,INT_VALUE);
   FileWriteInteger(h,D,INT_VALUE);
   FileWriteInteger(h,K,INT_VALUE);
   FileWriteInteger(h,tradable?1:0,INT_VALUE);
   FileWriteInteger(h,valSignals,INT_VALUE);
   FileWriteLong(h,(long)lastTrain);
   FileWriteDouble(h,trainLL); FileWriteDouble(h,validLL); FileWriteDouble(h,valEdgeBp);
   for(int d=0;d<D;d++){ FileWriteDouble(h,fMean[d]); FileWriteDouble(h,fStd[d]); }
   for(int i=0;i<N;i++)   FileWriteDouble(h,pi[i]);
   for(int i=0;i<N*N;i++) FileWriteDouble(h,A[i]);
   for(int i=0;i<N*D;i++) FileWriteDouble(h,mu[i]);
   for(int i=0;i<N*D;i++) FileWriteDouble(h,var[i]);
   FileClose(h);
   return true;
}

bool CHMM::Load(const string file)
{
   if(!FileIsExist(file)) return false;
   int h=FileOpen(file,FILE_READ|FILE_BIN);
   if(h==INVALID_HANDLE) return false;
   int ver=(int)FileReadInteger(h,INT_VALUE);
   int n  =(int)FileReadInteger(h,INT_VALUE);
   int d  =(int)FileReadInteger(h,INT_VALUE);
   int k  =(int)FileReadInteger(h,INT_VALUE);
   if(ver!=MODEL_VERSION||n<2||n>16||d!=DIMS||k!=InpReturnHorizon){ FileClose(h); return false; }
   Allocate(n,d); K=k;
   tradable  =(FileReadInteger(h,INT_VALUE)==1);
   valSignals=(int)FileReadInteger(h,INT_VALUE);
   lastTrain =(datetime)FileReadLong(h);
   trainLL=FileReadDouble(h); validLL=FileReadDouble(h); valEdgeBp=FileReadDouble(h);
   for(int i=0;i<D;i++){ fMean[i]=FileReadDouble(h); fStd[i]=FileReadDouble(h); }
   for(int i=0;i<N;i++)   pi[i] =FileReadDouble(h);
   for(int i=0;i<N*N;i++) A[i]  =FileReadDouble(h);
   for(int i=0;i<N*D;i++) mu[i] =FileReadDouble(h);
   for(int i=0;i<N*D;i++) var[i]=FileReadDouble(h);
   FileClose(h);
   trained=Sane();
   return trained;
}

//==================================================================
//  GLOBALES
//==================================================================
CTrade        trade;
CPositionInfo pos;
CHMM          model;
int           hATR=INVALID_HANDLE;
int           hStoch=INVALID_HANDLE;
datetime      lastBarTime=0;
int           barsSinceTrain=0;
bool          firstTrainDone=false;
string        modelFile="";
double        g_probUp=0.5,g_edge=0.0,g_atr=0.0,g_post[];
int           g_state=-1,g_stochDir=0;
string        g_reason="sin datos";
// resultados de la medicion del modulo de reversion
double        g_stoEdgeBp=0.0,g_stoLongBp=0.0,g_stoShortBp=0.0,g_stoHit=0.0;
int           g_stoSignals=0;
bool          g_stoTradable=false;

bool UsesHMM(void)
{ return (InpEntryMode!=ENTRY_STOCH_ONLY); }
bool UsesStoch(void)
{ return (InpEntryMode!=ENTRY_HMM_ONLY); }

//==================================================================
//  UTILIDADES
//==================================================================
double NormCDF(const double z)
{
   double x=z/MathSqrt(2.0);
   int sign=(x<0)?-1:1;
   x=MathAbs(x);
   double t=1.0/(1.0+0.3275911*x);
   double y=1.0-(((((1.061405429*t-1.453152027)*t)+1.421413741)*t-0.284496736)*t+0.254829592)*t*MathExp(-x*x);
   return 0.5*(1.0+sign*y);
}

int BuildRaw(const int shift,const int count,const int K,double &raw[],double &ret1[])
{
   MqlRates r[];
   ArraySetAsSeries(r,false);
   int got=CopyRates(_Symbol,_Period,shift,count+K,r);
   if(got<K+20) return 0;
   int T=got-K;
   ArrayResize(raw,T*DIMS); ArrayResize(ret1,T);
   for(int t=0; t<T; t++)
   {
      int i=t+K;
      double c1=r[i].close,c0=r[i-K].close,cp=r[i-1].close;
      if(c1<=0.0||c0<=0.0||cp<=0.0) return 0;
      raw[t*DIMS+0]=MathLog(c1/c0);
      raw[t*DIMS+1]=(r[i].high-r[i].low)/c1;
      ret1[t]=MathLog(c1/cp);
   }
   return T;
}

void ApplyStd(double &x[],const int T,const double &fm[],const double &fs[])
{
   for(int t=0;t<T;t++)
      for(int d=0;d<DIMS;d++)
         x[t*DIMS+d]=(x[t*DIMS+d]-fm[d])/fs[d];
}

void SignalFromPost(const CHMM &m,const double &post[],
                    double &probUp,double &expRet,int &domState)
{
   int N=m.N;
   double nxt[]; ArrayResize(nxt,N); ArrayInitialize(nxt,0.0);
   for(int i=0;i<N;i++)
      for(int j=0;j<N;j++)
         nxt[j]+=post[i]*m.A[i*N+j];
   domState=ArrayMaximum(nxt,0,N);
   probUp=0.0; expRet=0.0;
   for(int j=0;j<N;j++)
   {
      double muK  =m.mu[j*DIMS+0]*m.fStd[0]+m.fMean[0];
      double drift=muK/MathMax(1,m.K);
      double rng  =m.mu[j*DIMS+1]*m.fStd[1]+m.fMean[1];
      double sig  =MathMax(PARKINSON*MathAbs(rng),1e-8);
      double aii  =MathMin(m.A[j*N+j],0.999);
      double h    =MathMax(MathMin(1.0/MathMax(1e-6,1.0-aii),InpMaxHorizon),1.0);
      probUp+=nxt[j]*NormCDF(drift*MathSqrt(h)/sig);
      expRet+=nxt[j]*drift*h;
   }
}

double GetATR(void)
{
   double buf[];
   if(CopyBuffer(hATR,0,1,1,buf)<1) return 0.0;
   return buf[0];
}

double NormalizeVolume(double lot)
{
   double vmin =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double vstep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vstep<=0.0) vstep=0.01;
   lot=MathFloor(lot/vstep)*vstep;
   return NormalizeDouble(MathMax(vmin,MathMin(vmax,lot)),2);
}

double CalcLot(const double slDistance)
{
   if(InpFixedLot>0.0) return NormalizeVolume(InpFixedLot);
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0.0||ts<=0.0||slDistance<=0.0)
      return NormalizeVolume(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   double lossPerLot=(slDistance/ts)*tv;
   if(lossPerLot<=0.0) return NormalizeVolume(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   return NormalizeVolume(AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0/lossPerLot);
}

bool HasPosition(long &type)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i))
         if(pos.Symbol()==_Symbol && pos.Magic()==InpMagic)
         { type=(long)pos.PositionType(); return true; }
   return false;
}

void ClosePosition(void)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(pos.SelectByIndex(i))
         if(pos.Symbol()==_Symbol && pos.Magic()==InpMagic)
            trade.PositionClose(pos.Ticket());
}

//<<<<<<<<<<<<<<<<< MODULO STOCH + VOLUMEN >>>>>>>>>>>>>>>>>>>>>>>>>
//  Idea: el cruce de %K sobre %D acompanado de volumen por encima
//  de la media reciente suele preceder un giro. Aqui se implementa
//  y, sobre todo, SE MIDE sobre el historial disponible.
//
//  Regla (evaluada solo en barras cerradas):
//    alcista: %K cruza al alza a %D, en zona de sobreventa,
//             y volumen de la barra > InpVolFactor x media previa
//    bajista: simetrico en sobrecompra
//------------------------------------------------------------------
bool GetVolumes(const int shift,const int count,double &v[])
{
   ArrayResize(v,count);
   if(InpUseRealVolume)
   {
      long rv[]; ArraySetAsSeries(rv,false);
      if(CopyRealVolume(_Symbol,_Period,shift,count,rv)<count) return false;
      bool allZero=true;
      for(int i=0;i<count;i++){ v[i]=(double)rv[i]; if(rv[i]>0) allZero=false; }
      if(allZero) return false;      // el broker no publica volumen real
      return true;
   }
   long tv[]; ArraySetAsSeries(tv,false);
   if(CopyTickVolume(_Symbol,_Period,shift,count,tv)<count) return false;
   for(int i=0;i<count;i++) v[i]=(double)tv[i];
   return true;
}

//  Detecta la senal en un indice t de arrays cronologicos.
//  Devuelve +1 (giro alcista), -1 (giro bajista) o 0.
int StochVolSignalAt(const double &k[],const double &d[],const double &v[],const int t)
{
   if(t<InpVolLookback+1) return 0;

   double volAvg=0.0;
   for(int i=t-InpVolLookback; i<t; i++) volAvg+=v[i];
   volAvg/=InpVolLookback;
   if(volAvg<=0.0) return 0;
   bool volOK=(v[t]>InpVolFactor*volAvg);
   if(!volOK) return 0;

   bool crossUp  =(k[t-1]<=d[t-1] && k[t]>d[t]);
   bool crossDown=(k[t-1]>=d[t-1] && k[t]<d[t]);

   if(crossUp)
   {
      if(!InpRequireZone || MathMin(k[t],k[t-1])<=InpOversold) return +1;
   }
   if(crossDown)
   {
      if(!InpRequireZone || MathMax(k[t],k[t-1])>=InpOverbought) return -1;
   }
   return 0;
}

//  Senal en vivo sobre la ultima barra cerrada (shift 1)
int StochVolSignalLive(void)
{
   int need=InpVolLookback+3;
   double k[],d[],v[];
   ArraySetAsSeries(k,false); ArraySetAsSeries(d,false);
   if(CopyBuffer(hStoch,0,1,need,k)<need) return 0;
   if(CopyBuffer(hStoch,1,1,need,d)<need) return 0;
   if(!GetVolumes(1,need,v)) return 0;
   return StochVolSignalAt(k,d,v,need-1);
}

//  Mide el edge historico de la regla: retorno medio a InpStochHold
//  barras vista tras cada senal, separado por direccion.
bool EvaluateStochEdge(const int bars)
{
   int need=MathMin(bars,Bars(_Symbol,_Period)-InpStochHold-5);
   if(need<InpVolLookback+50) return false;

   double k[],d[],v[];
   ArraySetAsSeries(k,false); ArraySetAsSeries(d,false);
   if(CopyBuffer(hStoch,0,1,need,k)<need) return false;
   if(CopyBuffer(hStoch,1,1,need,d)<need) return false;
   if(!GetVolumes(1,need,v)) return false;

   MqlRates r[]; ArraySetAsSeries(r,false);
   if(CopyRates(_Symbol,_Period,1,need,r)<need) return false;

   double sumL=0.0,sumS=0.0; int nL=0,nS=0,nWin=0;
   for(int t=InpVolLookback+1; t<need-InpStochHold; t++)
   {
      int s=StochVolSignalAt(k,d,v,t);
      if(s==0) continue;
      double fwd=MathLog(r[t+InpStochHold].close/r[t].close);
      if(s>0){ sumL+=fwd; nL++; if(fwd>0) nWin++; }
      else   { sumS+=fwd; nS++; if(fwd<0) nWin++; }
   }

   g_stoSignals=nL+nS;
   if(g_stoSignals==0){ g_stoEdgeBp=0; g_stoTradable=false; return false; }

   g_stoLongBp =(nL>0)?sumL/nL*1e4:0.0;
   g_stoShortBp=(nS>0)?sumS/nS*1e4:0.0;
   g_stoEdgeBp =(sumL-sumS)/g_stoSignals*1e4;
   g_stoHit    =(double)nWin/g_stoSignals;

   PrintFormat("REVERSION stoch+vol: %d senales (L=%d S=%d) | a %d barras: mediaL=%+.1f pb  mediaS=%+.1f pb | edge=%+.1f pb | acierto=%.1f%%",
               g_stoSignals,nL,nS,InpStochHold,g_stoLongBp,g_stoShortBp,g_stoEdgeBp,g_stoHit*100.0);

   g_stoTradable=(!InpRequireValid ||
                  (g_stoSignals>=InpMinValSignals && g_stoEdgeBp>InpMinValEdgeBp));
   if(!g_stoTradable)
      Print("La regla de reversion NO muestra edge en este historial: no se operara con ella.");
   return g_stoTradable;
}
//<<<<<<<<<<<<<<<<<<<<<< FIN MODULO >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

//==================================================================
//  VALIDACION DEL HMM
//==================================================================
bool ValidateModel(CHMM &m,const double &xs[],const double &ret1[],
                   const int T,const int startIdx,const double atrRel)
{
   double alpha[];
   if(!m.FilterAll(xs,T,alpha)) return false;
   int N=m.N;
   double post[]; ArrayResize(post,N);
   double sumL=0.0,sumS=0.0; int nL=0,nS=0;

   for(int t=startIdx; t<T-1; t++)
   {
      for(int i=0;i<N;i++) post[i]=alpha[t*N+i];
      double p,e; int st;
      SignalFromPost(m,post,p,e,st);
      double thr=InpMinEdgeATR*atrRel;
      if(p>=InpMinProb && e>thr)            { sumL+=ret1[t+1]; nL++; }
      else if(p<=1.0-InpMinProb && e<-thr)  { sumS+=ret1[t+1]; nS++; }
   }
   m.valSignals=nL+nS;
   if(m.valSignals<=0){ m.valEdgeBp=0.0; return false; }
   m.valEdgeBp=((sumL-sumS)/m.valSignals)*1e4;
   PrintFormat("HMM validacion: %d senales (L=%d S=%d) | edge=%.3f pb/barra",
               m.valSignals,nL,nS,m.valEdgeBp);
   return (m.valSignals>=InpMinValSignals && m.valEdgeBp>InpMinValEdgeBp);
}

//==================================================================
//  ENTRENAMIENTO
//==================================================================
bool TrainModel(void)
{
   int K=MathMax(1,InpReturnHorizon);
   if(Bars(_Symbol,_Period)<InpTrainBars+K+InpATRPeriod+20)
   {
      if(InpDebug) PrintFormat("Historial insuficiente: %d barras, necesarias %d",
                               Bars(_Symbol,_Period),InpTrainBars+K+InpATRPeriod+20);
      return false;
   }
   double raw[],ret1[];
   int T=BuildRaw(1,InpTrainBars,K,raw,ret1);
   if(T<300) return false;

   double fm[],fs[];
   ArrayResize(fm,DIMS); ArrayResize(fs,DIMS);
   for(int d=0;d<DIMS;d++)
   {
      double s=0.0,s2=0.0;
      for(int t=0;t<T;t++){ double v=raw[t*DIMS+d]; s+=v; s2+=v*v; }
      fm[d]=s/T;
      fs[d]=MathSqrt(MathMax(s2/T-fm[d]*fm[d],1e-20));
      if(fs[d]<=0.0) return false;
   }
   double atrRel=fm[1];

   double xs[]; ArrayResize(xs,T*DIMS); ArrayCopy(xs,raw);
   ApplyStd(xs,T,fm,fs);

   int Tv=(int)MathMax(60,MathRound(T*InpValidFrac));
   int Tt=T-Tv;
   if(Tt<200){ Tt=T; Tv=0; }

   double xt[],xv[];
   ArrayResize(xt,Tt*DIMS); ArrayCopy(xt,xs,0,0,Tt*DIMS);
   if(Tv>0){ ArrayResize(xv,Tv*DIMS); ArrayCopy(xv,xs,0,Tt*DIMS,Tv*DIMS); }

   CHMM best; bool haveBest=false; double bestScore=-DBL_MAX;
   for(int r=0;r<MathMax(1,InpRestarts);r++)
   {
      CHMM cand;
      cand.Allocate(InpStates,DIMS);
      cand.K=K;
      ArrayCopy(cand.fMean,fm); ArrayCopy(cand.fStd,fs);
      cand.RandomInit(xt,Tt);
      double ll=cand.EM(xt,Tt,InpMaxIter,InpTol);
      if(!MathIsValidNumber(ll)||!cand.Sane()) continue;
      double score=ll/Tt;
      if(Tv>0)
      {
         double vll=cand.LogLik(xv,Tv);
         if(!MathIsValidNumber(vll)) continue;
         cand.validLL=vll;
         score=vll/Tv;
      }
      if(score>bestScore){ bestScore=score; best.CopyFrom(cand); haveBest=true; }
   }
   if(!haveBest){ Print("Entrenamiento fallido."); return false; }

   best.K=K;
   ArrayCopy(best.fMean,fm); ArrayCopy(best.fStd,fs);
   if(!best.Sane()) return false;
   best.trained=true;
   best.lastTrain=iTime(_Symbol,_Period,0);

   bool ok=true;
   if(Tv>0) ok=ValidateModel(best,xs,ret1,T,Tt,atrRel);
   best.tradable=(!InpRequireValid||ok);

   model.CopyFrom(best);
   barsSinceTrain=0;
   firstTrainDone=true;
   if(InpGuardarModelo) model.Save(modelFile);

   string msg="HMM entrenado | T="+IntegerToString(T)+" K="+IntegerToString(K)+
              " | operable="+(model.tradable?"SI":"NO")+" | estados:";
   for(int i=0;i<model.N;i++)
   {
      double muK=model.mu[i*DIMS+0]*model.fStd[0]+model.fMean[0];
      msg+=StringFormat(" s%d[drift=%+.2fpb A_ii=%.2f]",i,muK/K*1e4,model.A[i*model.N+i]);
   }
   Print(msg);
   return true;
}

//==================================================================
//  INFERENCIA HMM EN VIVO
//==================================================================
bool Inference(double &probUp,double &expMovePrice,int &domState)
{
   if(!model.trained) return false;
   int K=MathMax(1,model.K);
   int W=MathMin(InpFilterBars,Bars(_Symbol,_Period)-K-5);
   if(W<60) return false;
   double raw[],ret1[];
   int T=BuildRaw(1,W,K,raw,ret1);
   if(T<30) return false;
   ApplyStd(raw,T,model.fMean,model.fStd);
   double alpha[];
   if(!model.FilterAll(raw,T,alpha)) return false;
   int N=model.N;
   double post[]; ArrayResize(post,N); ArrayResize(g_post,N);
   for(int i=0;i<N;i++){ post[i]=alpha[(T-1)*N+i]; g_post[i]=post[i]; }
   double expRet;
   SignalFromPost(model,post,probUp,expRet,domState);
   expMovePrice=expRet*SymbolInfoDouble(_Symbol,SYMBOL_BID);
   return true;
}

//==================================================================
//  ORDENES
//==================================================================
void OpenTrade(const bool isBuy,const double atr,const string origen)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slDist=InpSL_ATR*atr;
   if(slDist<=0.0) return;
   double stopLevel=(double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(slDist<stopLevel*1.2) slDist=stopLevel*1.2;

   double lot=CalcLot(slDist);
   double price=isBuy?ask:bid;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double sl=NormalizeDouble(isBuy?price-slDist:price+slDist,dg);
   double tp=0.0;
   if(InpTP_ATR>0.0) tp=NormalizeDouble(isBuy?price+InpTP_ATR*atr:price-InpTP_ATR*atr,dg);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   bool ok=isBuy?trade.Buy(lot,_Symbol,0.0,sl,tp,InpComentario+"-"+origen)
                :trade.Sell(lot,_Symbol,0.0,sl,tp,InpComentario+"-"+origen);
   if(!ok) PrintFormat("Error al abrir %s lot=%.2f: %d %s",isBuy?"BUY":"SELL",lot,
                       trade.ResultRetcode(),trade.ResultRetcodeDescription());
   else    PrintFormat("Abierta %s lot=%.2f por %s | P=%.3f edge=%.1fpts stoch=%d",
                       isBuy?"BUY":"SELL",lot,origen,g_probUp,g_edge/_Point,g_stochDir);
}

void ManageTrailing(const double atr)
{
   if(!InpUseTrailing||atr<=0.0) return;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double dist=InpTrail_ATR*atr;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(!pos.SelectByIndex(i)) continue;
      if(pos.Symbol()!=_Symbol||pos.Magic()!=InpMagic) continue;
      double sl=pos.StopLoss(),tp=pos.TakeProfit();
      if(pos.PositionType()==POSITION_TYPE_BUY)
      {
         double nsl=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_BID)-dist,dg);
         if(nsl>pos.PriceOpen()&&(sl==0.0||nsl>sl+_Point)) trade.PositionModify(pos.Ticket(),nsl,tp);
      }
      else
      {
         double nsl=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_ASK)+dist,dg);
         if(nsl<pos.PriceOpen()&&(sl==0.0||nsl<sl-_Point)) trade.PositionModify(pos.Ticket(),nsl,tp);
      }
   }
}

//==================================================================
//  PANEL
//==================================================================
void ShowPanel(void)
{
   if(!InpPanel) return;
   string modo[]={"Solo HMM","Solo reversion","Reversion filtrada por HMM","Cualquiera"};
   string s="=== HMM + Reversion v1.2 ===\n"+_Symbol+"  "+
            EnumToString((ENUM_TIMEFRAMES)_Period)+"   Modo: "+modo[(int)InpEntryMode]+"\n";

   if(UsesStoch())
   {
      s+="Reversion: "+IntegerToString(g_stoSignals)+" senales historicas | L="+
         DoubleToString(g_stoLongBp,1)+"pb  S="+DoubleToString(g_stoShortBp,1)+
         "pb  edge="+DoubleToString(g_stoEdgeBp,1)+"pb  acierto="+
         DoubleToString(g_stoHit*100,1)+"%  operable="+(g_stoTradable?"SI":"NO")+"\n";
      s+="Senal actual: "+(g_stochDir>0?"GIRO ALCISTA":(g_stochDir<0?"GIRO BAJISTA":"ninguna"))+"\n";
   }
   if(UsesHMM())
   {
      if(!model.trained) s+="HMM: SIN ENTRENAR\n";
      else
      {
         s+="HMM operable="+(model.tradable?"SI":"NO")+"  edge val="+
            DoubleToString(model.valEdgeBp,3)+"pb  reentrena en "+
            IntegerToString(MathMax(0,InpRetrainBars-barsSinceTrain))+" barras\n";
         s+="P(a favor)="+DoubleToString(g_probUp*100,1)+"%  Edge="+
            DoubleToString(g_edge/_Point,1)+"pts (umbral "+
            DoubleToString(InpMinEdgeATR*g_atr/_Point,1)+")\n";
      }
   }
   s+="Estado: "+g_reason;
   Comment(s);
}

//==================================================================
//  EVENTOS
//==================================================================
int OnInit()
{
   if(InpStates<2||InpStates>16) return INIT_PARAMETERS_INCORRECT;
   if(InpReturnHorizon<1||InpReturnHorizon>100) return INIT_PARAMETERS_INCORRECT;
   if(InpValidFrac<0.0||InpValidFrac>0.5) return INIT_PARAMETERS_INCORRECT;
   if(InpVolLookback<3||InpStochHold<1) return INIT_PARAMETERS_INCORRECT;

   MathSrand(InpSeed>0?InpSeed:(int)GetTickCount());

   hATR=iATR(_Symbol,_Period,InpATRPeriod);
   if(hATR==INVALID_HANDLE) return INIT_FAILED;

   hStoch=iStochastic(_Symbol,_Period,InpStochK,InpStochD,InpStochSlow,MODE_SMA,STO_LOWHIGH);
   if(hStoch==INVALID_HANDLE){ Print("No se pudo crear el estocastico"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("AVISO: AutoTrading desactivado en el terminal.");
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("AVISO: este EA no tiene permiso de trading.");

   modelFile="HMM_"+_Symbol+"_"+IntegerToString((int)_Period)+"_"+IntegerToString((int)InpMagic)+".bin";

   if(UsesHMM() && InpGuardarModelo && model.Load(modelFile))
   {
      Print("Modelo cargado (",TimeToString(model.lastTrain),") operable=",model.tradable?"SI":"NO");
      firstTrainDone=true; barsSinceTrain=0;
   }
   else if(UsesHMM())
   {
      model.Allocate(InpStates,DIMS);
      model.K=InpReturnHorizon;
   }

   lastBarTime=iTime(_Symbol,_Period,0);
   g_reason="esperando barra";
   ShowPanel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(UsesHMM()&&InpGuardarModelo&&model.trained) model.Save(modelFile);
   if(hATR!=INVALID_HANDLE)   IndicatorRelease(hATR);
   if(hStoch!=INVALID_HANDLE) IndicatorRelease(hStoch);
   Comment("");
}

void OnTick()
{
   double atr=GetATR();
   g_atr=atr;
   ManageTrailing(atr);

   datetime bt=iTime(_Symbol,_Period,0);
   if(bt==lastBarTime) return;
   lastBarTime=bt;
   barsSinceTrain++;

   // ---- entrenamiento y medicion periodica ----
   if(UsesHMM() && (!firstTrainDone||barsSinceTrain>=InpRetrainBars))
   {
      uint t0=GetTickCount();
      if(TrainModel())
      {
         PrintFormat("Entrenamiento en %u ms",GetTickCount()-t0);
         if(UsesStoch()) EvaluateStochEdge(InpTrainBars);
      }
   }
   else if(UsesStoch() && (!firstTrainDone||barsSinceTrain>=InpRetrainBars))
   {
      EvaluateStochEdge(InpTrainBars);
      barsSinceTrain=0; firstTrainDone=true;
   }

   // ---- senales ----
   bool hmmBuy=false,hmmSell=false,hmmOK=false;
   if(UsesHMM() && model.trained)
   {
      double p,e; int st;
      if(Inference(p,e,st))
      {
         g_probUp=p; g_edge=e; g_state=st;
         double thr=InpMinEdgeATR*atr;
         hmmBuy =(p>=InpMinProb     && e> thr);
         hmmSell=(p<=1.0-InpMinProb && e<-thr);
         hmmOK  =(model.tradable||!InpRequireValid);
      }
   }

   g_stochDir=0;
   if(UsesStoch()) g_stochDir=StochVolSignalLive();
   bool stoOK=(g_stoTradable||!InpRequireValid);

   bool wantBuy=false,wantSell=false;
   string origen="";
   switch(InpEntryMode)
   {
      case ENTRY_HMM_ONLY:
         wantBuy=hmmBuy&&hmmOK; wantSell=hmmSell&&hmmOK; origen="HMM";
         break;
      case ENTRY_STOCH_ONLY:
         wantBuy=(g_stochDir>0)&&stoOK; wantSell=(g_stochDir<0)&&stoOK; origen="REV";
         break;
      case ENTRY_STOCH_FILTER:
         // el giro manda, pero el HMM puede vetarlo si apunta al contrario
         wantBuy =(g_stochDir>0)&&stoOK&&!(hmmSell&&hmmOK);
         wantSell=(g_stochDir<0)&&stoOK&&!(hmmBuy &&hmmOK);
         origen="REV+HMM";
         break;
      case ENTRY_ANY:
         wantBuy =((g_stochDir>0)&&stoOK)||(hmmBuy &&hmmOK);
         wantSell=((g_stochDir<0)&&stoOK)||(hmmSell&&hmmOK);
         origen=(g_stochDir!=0)?"REV":"HMM";
         break;
   }

   if(InpDebug)
      PrintFormat("%s | stoch=%+d P=%.3f edge=%.1fpts | hmmOK=%d stoOK=%d -> %s",
                  TimeToString(bt,TIME_DATE|TIME_MINUTES),g_stochDir,g_probUp,
                  g_edge/_Point,hmmOK,stoOK,wantBuy?"BUY":(wantSell?"SELL":"nada"));

   if(atr<=0.0){ g_reason="ATR no disponible"; ShowPanel(); return; }
   double spread=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   bool spreadOK=(spread<=InpMaxSpreadPts);

   long ptype; bool inPos=HasPosition(ptype);
   if(inPos)
   {
      bool isLong=(ptype==POSITION_TYPE_BUY);
      bool revContra=InpStochExit&&((isLong&&g_stochDir<0)||(!isLong&&g_stochDir>0));
      bool flip=InpCloseOnFlip&&((isLong&&wantSell)||(!isLong&&wantBuy));
      if(revContra||flip)
      {
         ClosePosition();
         g_reason=revContra?"cierre por giro contrario":"senal invertida";
         if(InpReverse&&spreadOK&&(wantBuy||wantSell)) OpenTrade(wantBuy,atr,origen);
      }
      else g_reason="en posicion";
   }
   else if(wantBuy||wantSell)
   {
      if(spreadOK){ OpenTrade(wantBuy,atr,origen); g_reason="entrada "+origen; }
      else g_reason="spread alto ("+DoubleToString(spread,0)+")";
   }
   else g_reason="sin senal";

   ShowPanel();
}
//+------------------------------------------------------------------+
