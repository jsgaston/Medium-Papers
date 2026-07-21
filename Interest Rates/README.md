# EA de tipos de interés (multisímbolo) para MT5

## Qué hace

`InterestRateEA.mq5` opera varios pares a la vez a partir de un CSV con
decisiones de tipos de interés de bancos centrales. Cuando una divisa ha
subido tipos recientemente y la otra pata del par no (o los ha bajado),
abre largo en la divisa fuerte / corto en la débil. Para XAUUSD y XAGUSD
aplica la relación inversa con USD (USD sube tipos → oro/plata bajan).

Cierra la posición si:
- pasan más de `InpHoldDays` días desde la apertura, o
- la señal se invierte antes de eso (si `InpCloseOnFlip=true`).

## 1. Instalación del EA

1. Copia `InterestRateEA.mq5` a `MQL5\Experts\` en tu terminal MT5 y
   compílalo en MetaEditor.
2. Copia `interest_rates.csv` a la carpeta `Common\Files` de MT5 (no a
   `MQL5\Files` del terminal individual), para que el mismo archivo sea
   visible desde el terminal en vivo **y** desde el Strategy Tester.
   - Ruta típica: `C:\Users\Public\Documents\MetaQuotes\Terminal\Common\Files\`
   - Puedes verla en MT5: `Archivo > Abrir carpeta de datos > ..\Common\Files`
3. Arrastra el EA a un gráfico (p.ej. EURUSD). No importa en qué gráfico
   lo pongas: el propio EA recorre internamente la lista de `InpSymbols`.
4. Activa "Algo Trading" y revisa que en `Herramientas > Opciones >
   Asesores Expertos` esté marcado "Permitir importación de DLL" si tu
   build lo requiere (no debería hacer falta, no usa DLLs) y que el
   símbolo de cada par de `InpSymbols` esté disponible en tu Market Watch
   / bróker.

## 1.1 Nuevos parámetros (SL/TP por ATR y frescura de señal)

- `InpATRPeriod` (14 por defecto), `InpSLAtrMult` (1.5) y `InpTPAtrMult` (2.0):
  al abrir, el EA calcula el ATR diario (últimas 14 velas D1 cerradas) y
  coloca SL = precio ± `InpSLAtrMult`×ATR y TP = precio ± `InpTPAtrMult`×ATR.
  Con 1.5/2.0 tienes un ratio riesgo:beneficio de 1:1.33; si quieres 1×ATR
  exacto en ambos lados, pon los dos a 1.0.
- `InpMaxAgeDays` ahora es 5 por defecto (antes 3): como los bancos centrales
  solo deciden cada 6-8 semanas (el SNB solo 4 veces al año), un margen de
  3 días se puede perder por un simple fin de semana. 5 días da colchón sin
  operar sobre noticias ya muy digeridas por el mercado.
- El EA ahora reintenta la apertura **en cada tick**, no solo una vez al día:
  así, si el primer tick del día cae en la ventana de cierre por rollover de
  medianoche (causa real del "Market closed" que veías), lo vuelve a intentar
  segundos/minutos después en vez de perder la señal ese día.

## 2. Formato del CSV

```
Date,Bank,Currency,Rate,PrevRate,Action
2026.06.18,FED,USD,4.25,4.50,CUT
```

- `Date` en formato `yyyy.mm.dd` (formato nativo de MQL5).
- `Action` debe ser `HIKE`, `CUT` o `HOLD` (en mayúsculas).
- Una fila por decisión/observación. No hace falta una fila diaria si no
  ha habido cambio, pero el script de Python (ver abajo) escribe una fila
  diaria de todas formas, marcando `HOLD` cuando no hay cambio — así
  siempre tienes constancia del último valor conocido.

## 3. Backtesting en el Strategy Tester

El Strategy Tester **sí puede leer `Common\Files`** con `FILE_COMMON`
(el input `InpUseCommon=true` ya lo activa), así que no necesitas nada
especial: mismo CSV para en vivo y para test.

Puntos importantes para que el backtest sea realista:

- El CSV debe contener **todo el histórico** de decisiones del periodo
  que vas a testear (no solo las últimas). El EA compara cada evento
  contra `TimeCurrent()` simulado y descarta los que sean posteriores a
  esa fecha — así evitas look-ahead bias (usar información "del futuro").
- Actualiza `InpMaxAgeDays` según la frecuencia de reacción que quieras
  simular (3 días por defecto = solo entra si la decisión es reciente).
- Para 8 símbolos en paralelo, el test necesita datos históricos de los 8
  pares para el periodo elegido — verifica que tu bróker/terminal tiene
  histórico suficiente para todos (Herramientas > Historial de datos).

## 4. Script de Python (actualización diaria)

`fetch_rates.py` añade una fila al CSV cada día para: Fed (API FRED),
BCE (API oficial ECB Data Portal) y Banco de Canadá (API Valet) de forma
automática. Para BOJ, SNB, RBA, RBNZ y BOE (que no tienen una API
gratuita tan directa) el script usa un diccionario `MANUAL_RATES` que
actualizas tú mismo cuando el banco cambie tipos; el script se encarga
de comparar contra el valor anterior y anotar HIKE/CUT/HOLD igual que
con las fuentes automáticas.

### Instalación

```bash
pip install requests
```

### Configuración

1. Consigue una API key gratuita de FRED:
   https://fred.stlouisfed.org/docs/api/api_key.html
2. Define las variables de entorno (o edítalas directamente en el script):
   ```
   set FRED_API_KEY=tu_clave
   set IR_CSV_PATH=C:\Users\Public\Documents\MetaQuotes\Terminal\Common\Files\interest_rates.csv
   ```
3. Ejecuta una vez a mano para comprobar que todo responde:
   ```
   python fetch_rates.py
   ```

### Programarlo a diario

**Windows (Task Scheduler):** crea una tarea que ejecute
`python C:\ruta\fetch_rates.py` una vez al día (por ejemplo a las 23:00,
después del cierre de mercado en EE.UU.).

**Linux/VPS con cron:**
```
0 23 * * * /usr/bin/python3 /ruta/fetch_rates.py >> /ruta/fetch_rates.log 2>&1
```

## 5. Fiabilidad de los datos históricos incluidos

El `interest_rates.csv` que te he dado ya viene con el histórico 2022-2026
de los 8 bancos (Fed, ECB, BOE, BOJ, SNB, BOC, RBA, RBNZ). Nivel de
confianza por tramo:

- **2023-2026**: verificado directamente contra tablas de global-rates.com
  (que a su vez recogen las decisiones oficiales de cada banco). Fechas y
  valores con alta confianza.
- **2022** (todo el ciclo de subidas inicial): completado con datos de mi
  conocimiento general, sin verificación directa reunión por reunión para
  todos los bancos. El orden de magnitud y la secuencia son correctos,
  pero antes de operar en real te recomiendo contrastar al menos las
  fechas exactas de 2022 contra la web oficial de cada banco (Fed:
  federalreserve.gov, ECB: ecb.europa.eu, BOE: bankofengland.co.uk, etc.).
- El SNB en 2025 tiene una fecha (2025.03.20) estimada por continuidad de
  la serie trimestral, no confirmada con la misma certeza que el resto.

Para un backtest de una estrategia (no para operar en real sin más
verificación), esto ya es suficientemente sólido: los ciclos, direcciones
y magnitudes generales son correctos.

## 6. Limitación honesta que debes tener en cuenta

La relación "sube tipos → sube la divisa / baja el oro" es una
simplificación. El mercado se mueve sobre todo por la **sorpresa**
respecto a lo que ya estaba descontado en los futuros de tipos, no por
la dirección del movimiento en sí. Un banco puede subir tipos y su
divisa caer si el mercado esperaba una subida mayor. Este EA solo mira
la dirección (HIKE/CUT/HOLD), no la sorpresa relativa a expectativas —
es un punto de partida razonable para forward testing, no una garantía
de edge real. Te recomendaría, como ya hemos hablado en tus otros
proyectos de EAs, probarlo primero en real con lotaje mínimo/demo antes
de escalarlo, igual que has hecho con tus otros sistemas.
