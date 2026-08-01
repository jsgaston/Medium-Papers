# OKX Grid-Fibonacci Backtester (multi-símbolo)

Backtester y grid search de parámetros para una estrategia de grid trading con
espaciado Fibonacci (inspirada en el paper de liquidez de Raydium, adaptada
aquí a un exchange centralizado — OKX — donde en vez de proveer liquidez a un
AMM se colocan órdenes límite escalonadas alrededor del precio).

## Qué incluye

| Fichero | Función |
|---|---|
| `config.yaml` | Símbolos, timeframe, rangos del grid search, fees, capital |
| `okx_downloader.py` | Descarga histórico OHLCV multi-símbolo desde la API pública de OKX |
| `okx_ws_collector.py` | Recolector WebSocket que construye tu propio histórico de order book (OKX no da L2 histórico gratis) |
| `strategy.py` | Lógica de la estrategia Grid-Fibonacci (niveles, tamaños, take-profit, re-centrado) |
| `backtester.py` | Motor de backtest, agrega resultados entre todos los símbolos |
| `grid_search.py` | Grid search paralelizado sobre los parámetros de la estrategia + heatmaps |
| `run_pipeline.py` | Orquesta descarga + grid search en un solo comando |

## Instalación en el VPS

```bash
cd okx_backtester
pip install -r requirements.txt
```

(En Windows, usa el mismo Python que ya tienes configurado para tus otros
scripts vía Task Scheduler.)

## 1. Descargar histórico OHLCV (multi-símbolo)

Edita `config.yaml` para ajustar la lista de `symbols`, el `timeframe` y
`history_days`. Por defecto trae 12 símbolos en velas de 15m y 2 años de
histórico — cuantos más símbolos, más robusto será el grid search (evita que
los parámetros óptimos estén sobreajustados a un solo activo).

```bash
python okx_downloader.py --config config.yaml
```

Es incremental: si lo vuelves a ejecutar más tarde, solo descarga las velas
nuevas desde la última guardada. Puedes programarlo en Task Scheduler para que
corra, por ejemplo, cada noche.

## 2. (Opcional pero recomendado) Recolectar order book real en segundo plano

OKX solo ofrece histórico L2 gratuito de forma limitada; para tener datos de
profundidad de mercado reales (no solo velas OHLC) hace falta ir
acumulándolos tú mismo desde ahora. Como tu VPS está encendido 24/7, déjalo
corriendo indefinidamente:

```bash
python okx_ws_collector.py --config config.yaml
```

Guarda snapshots del top 5 de bid/ask cada `snapshot_every_sec` segundos, un
CSV por símbolo y día en `data/orderbook_snapshots/`. Con unos meses de esto
acumulado, el backtest podrá simular fills con mucha más fidelidad que solo
con velas OHLC (que asumen que tocar un nivel = orden llena, sin considerar
que el nivel pudiera no tener suficiente profundidad real).

**Task Scheduler (Windows):**
- Programa: `python.exe`
- Argumentos: `C:\ruta\okx_backtester\okx_ws_collector.py --config C:\ruta\okx_backtester\config.yaml`
- Desencadenador: al iniciar el sistema
- Marca "reiniciar si falla" — el script ya reconecta solo si se cae el WebSocket, pero por si el proceso entero muere

## 3. Correr el grid search

```bash
python grid_search.py --config config.yaml --metric mean_sharpe
```

Prueba automáticamente todas las combinaciones de:
- `num_levels_grid` (número de niveles Fibonacci)
- `price_deviation_multiplier_grid` (cuánto se abre el grid respecto al precio)
- `size_scaling_factor_grid` (cuánto crece el tamaño de orden en niveles más lejanos)
- `regrid_threshold_grid` (cuándo se recentra el grid completo)

...sobre **todos los símbolos a la vez**, usando todos los cores disponibles
(`--workers N` para forzar un número concreto).

Salida:
- `results/grid_search_results.csv` — todas las combinaciones con sus métricas
- `results/heatmap_*.png` — heatmaps 2D (num_levels × price_deviation) por
  cada combinación de size_scaling_factor / regrid_threshold, coloreados por
  la métrica elegida (igual que el heatmap de `stddev` vs
  `moving_average_length` del artículo de Raydium)

Métricas disponibles con `--metric`: `mean_sharpe`, `mean_return_pct`,
`median_return_pct`, `worst_return_pct` (el peor símbolo — útil para evitar
parámetros frágiles), `mean_profit_factor`.

## 4. Todo en un comando

```bash
python run_pipeline.py --config config.yaml
```

Descarga datos frescos y corre el grid search seguido. Añade
`--skip-download` si solo quieres re-optimizar con los datos que ya tienes.

## 5. Paper trading en vivo (validación out-of-sample real)

Antes de arriesgar capital real, corre la estrategia con dinero virtual contra
el feed de precios en tiempo real de OKX durante un mes. Esto es una
validación mucho más fiable que el grid search (que es 100% in-sample sobre
el mismo histórico que optimizó).

`paper_trading_config.yaml` ya trae precargada la combinación ganadora de tu
grid search (`num_levels=3, price_deviation_multiplier=0.5,
size_scaling_factor=0.5, regrid_threshold=0.618`). Ajusta
`capital_per_symbol_usdt` si quieres.

```bash
python paper_trading_bot.py --config paper_trading_config.yaml
```

- **No envía ninguna orden real** — todo el cash/posición es virtual, se
  conecta solo al canal público de tickers de OKX (precio real en vivo).
- Reutiliza literalmente la misma lógica de `strategy.py` que ya validaste en
  el backtest (misma función `_build_grid`, mismos criterios de fill y
  re-centrado), así que el mes de paper trading mide de verdad la misma
  estrategia, no una versión distinta.
- Registra cada fill en `paper_trading_logs/trades.csv` y un snapshot de
  equity cada `equity_snapshot_interval_sec` en `paper_trading_logs/equity.csv`.
- Guarda el estado completo en `paper_trading_state/state.json` cada
  `state_save_interval_sec` — si el proceso o el VPS se reinician, al
  relanzar el script recupera exactamente donde se quedó (no pierdes el mes).
- Para pararlo de forma segura: `Ctrl+C` (guarda el estado y muestra un
  resumen antes de salir).

**Task Scheduler (Windows), igual que el recolector de order book:**
- Programa: `python.exe`
- Argumentos: `C:\ruta\okx_backtester\paper_trading_bot.py --config C:\ruta\okx_backtester\paper_trading_config.yaml`
- Desencadenador: al iniciar el sistema (+ reintentar si falla)

### Revisar resultados en cualquier momento

No hace falta parar el bot para ver cómo va:

```bash
python paper_trading_report.py --config paper_trading_config.yaml
```

Imprime por símbolo: retorno total, máximo drawdown, Sharpe anualizado,
número de trades, win rate y profit factor — y genera
`paper_trading_logs/equity_curves.png` con las curvas de equity normalizadas
de todos los símbolos superpuestas.

## Limitaciones a tener en cuenta

- **El backtest usa velas OHLC, no order book real.** Asume que si el precio
  de la vela toca un nivel, la orden se llena al precio del nivel (menos el
  slippage configurado). Es una aproximación razonable para una primera
  criba de parámetros, pero no captura si en ese instante había profundidad
  real suficiente en el libro. El recolector de WebSocket (paso 2) es la vía
  para ir corrigiendo esto con datos propios reales con el tiempo.
- **Comisiones:** revisa tu nivel VIP real en OKX y ajusta `fees.maker` /
  `fees.taker` en `config.yaml` — la rentabilidad simulada es muy sensible a
  esto en estrategias de grid con muchas operaciones.
- **Rate limits:** el downloader respeta `requests_per_second` en la config;
  si tu VPS comparte IP con otros procesos que también llaman a la API de
  OKX, bájalo.
- Igual que en tus EAs de MT5, recomendable validar cualquier configuración
  ganadora del grid search con forward testing (o al menos out-of-sample:
  parte de los símbolos/periodo fuera del grid search) antes de asignarle
  capital real, para evitar overfitting a los datos históricos usados.
- **Sobre el mes de paper trading:** un mes es un periodo corto — suficiente
  para detectar bugs de ejecución o un comportamiento claramente roto, pero
  no para confirmar estadísticamente que la ventaja del backtest es real
  (para eso harían falta bastantes más ciclos de regrid/trade de los que un
  mes suele dar). Trátalo como primer filtro, no como confirmación definitiva.
