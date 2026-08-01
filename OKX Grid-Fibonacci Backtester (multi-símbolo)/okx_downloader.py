"""
okx_downloader.py
==================
Descarga histórico OHLCV multi-símbolo desde la API pública de OKX (sin necesidad
de API key, son endpoints de mercado públicos) y lo guarda en CSV, uno por símbolo.

Usa dos endpoints combinados porque OKX separa el histórico reciente del antiguo:
  - /api/v5/market/candles          -> velas recientes (últimos ~1440-2160 registros)
  - /api/v5/market/history-candles  -> velas más antiguas, paginando hacia atrás

Uso:
    python okx_downloader.py --config config.yaml
    python okx_downloader.py --config config.yaml --symbols BTC-USDT ETH-USDT
    python okx_downloader.py --config config.yaml --timeframe 1H --history-days 365

Notas:
  - Respeta el rate limit configurado (requests_per_second) para no que OKX
    devuelva 429. Si tu VPS comparte IP con otros procesos, baja este valor.
  - Los ficheros se guardan como data/ohlcv/<SYMBOL>_<TIMEFRAME>.csv
  - Si el fichero ya existe, el script solo descarga las velas que faltan
    (incremental), así puedes re-ejecutarlo periódicamente en el VPS.
"""

import argparse
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import pandas as pd
import requests
import yaml
from tqdm import tqdm

CANDLES_ENDPOINT = "/api/v5/market/candles"
HISTORY_CANDLES_ENDPOINT = "/api/v5/market/history-candles"

COLUMNS = ["ts", "open", "high", "low", "close", "volume", "vol_ccy", "vol_ccy_quote", "confirm"]


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


class RateLimiter:
    def __init__(self, requests_per_second: float):
        self.min_interval = 1.0 / max(requests_per_second, 0.1)
        self._last_call = 0.0

    def wait(self):
        elapsed = time.monotonic() - self._last_call
        if elapsed < self.min_interval:
            time.sleep(self.min_interval - elapsed)
        self._last_call = time.monotonic()


def fetch_candles(base_url, symbol, bar, after=None, before=None, limiter=None, use_history=False):
    """Llama a un único page de velas. `after` = solo velas con ts < after (hacia atrás en el tiempo)."""
    endpoint = HISTORY_CANDLES_ENDPOINT if use_history else CANDLES_ENDPOINT
    params = {"instId": symbol, "bar": bar, "limit": 100 if use_history else 300}
    if after is not None:
        params["after"] = str(after)
    if before is not None:
        params["before"] = str(before)

    if limiter:
        limiter.wait()

    resp = requests.get(base_url + endpoint, params=params, timeout=15)
    resp.raise_for_status()
    payload = resp.json()
    if payload.get("code") != "0":
        raise RuntimeError(f"OKX API error for {symbol}: {payload}")
    return payload.get("data", [])


def download_symbol_history(base_url, symbol, bar, oldest_ts_wanted_ms, limiter, existing_oldest_ts=None):
    """
    Descarga velas desde ahora hacia atrás hasta oldest_ts_wanted_ms (o hasta que
    la API deje de devolver datos). Devuelve lista de filas [ts, o, h, l, c, vol, ...].
    """
    all_rows = []
    after = None  # None = empezar desde las velas más recientes
    use_history = False  # primero probamos el endpoint "candles" (reciente)
    stagnant_pages = 0

    pbar = tqdm(desc=f"{symbol} ({bar})", unit="pages", leave=False)
    while True:
        try:
            rows = fetch_candles(base_url, symbol, bar, after=after, limiter=limiter, use_history=use_history)
        except requests.HTTPError as e:
            # Si el endpoint reciente falla o se queda sin datos, probamos el histórico
            if not use_history:
                use_history = True
                continue
            print(f"  [WARN] {symbol}: fallo HTTP ({e}), abortando esta descarga.")
            break

        if not rows:
            if not use_history:
                # Se acabaron las velas recientes -> saltar al endpoint histórico
                use_history = True
                continue
            break  # también se acabó el histórico antiguo

        all_rows.extend(rows)
        pbar.update(1)

        oldest_ts_in_page = int(rows[-1][0])  # OKX devuelve más reciente primero
        after = oldest_ts_in_page

        if oldest_ts_in_page <= oldest_ts_wanted_ms:
            break
        if existing_oldest_ts is not None and oldest_ts_in_page <= existing_oldest_ts:
            break  # ya tenemos datos incrementales previos hasta aquí

        # Si dos páginas seguidas devuelven el mismo timestamp más antiguo, cortamos
        # para evitar bucles infinitos por peculiaridades de la API.
        if len(all_rows) > 2 and int(all_rows[-2][0]) == oldest_ts_in_page:
            stagnant_pages += 1
            if stagnant_pages > 2:
                break
        else:
            stagnant_pages = 0

    pbar.close()
    return all_rows


def rows_to_dataframe(rows):
    if not rows:
        return pd.DataFrame(columns=COLUMNS)
    df = pd.DataFrame(rows, columns=COLUMNS[: len(rows[0])])
    for c in ["open", "high", "low", "close", "volume", "vol_ccy"]:
        if c in df.columns:
            df[c] = df[c].astype(float)
    # OJO: en Windows, numpy resuelve "int" (C long) a 32 bits, y los timestamps
    # en milisegundos (~1.7 billones) desbordan esa capacidad. Hay que forzar
    # explícitamente int64 (64 bits) o revienta con "Python int too large to
    # convert to C long".
    df["ts"] = df["ts"].astype("int64")
    df["datetime"] = pd.to_datetime(df["ts"], unit="ms", utc=True)
    df = df.sort_values("ts").drop_duplicates(subset="ts").reset_index(drop=True)
    return df


def update_symbol_csv(base_url, symbol, bar, history_days, data_dir, limiter):
    os.makedirs(data_dir, exist_ok=True)
    out_path = os.path.join(data_dir, f"{symbol.replace('-', '_')}_{bar}.csv")

    oldest_wanted = int((datetime.now(timezone.utc) - timedelta(days=history_days)).timestamp() * 1000)

    existing_oldest_ts = None
    existing_df = None
    if os.path.exists(out_path):
        existing_df = pd.read_csv(out_path)
        if not existing_df.empty:
            existing_oldest_ts = int(existing_df["ts"].min())
            # Si ya tenemos histórico suficientemente antiguo, solo hace falta
            # traer las velas nuevas desde la última guardada.
            newest_existing_ts = int(existing_df["ts"].max())
            oldest_wanted = max(oldest_wanted, 0)
        else:
            existing_oldest_ts = None

    rows = download_symbol_history(
        base_url, symbol, bar, oldest_ts_wanted_ms=oldest_wanted,
        limiter=limiter, existing_oldest_ts=None
    )
    new_df = rows_to_dataframe(rows)

    if existing_df is not None and not existing_df.empty:
        combined = pd.concat([existing_df, new_df], ignore_index=True)
        combined = combined.sort_values("ts").drop_duplicates(subset="ts").reset_index(drop=True)
    else:
        combined = new_df

    combined.to_csv(out_path, index=False)
    return out_path, len(combined)


def main():
    parser = argparse.ArgumentParser(description="Descarga histórico OHLCV multi-símbolo de OKX")
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--symbols", nargs="*", default=None, help="Override de símbolos, ej: BTC-USDT ETH-USDT")
    parser.add_argument("--timeframe", default=None, help="Override del timeframe, ej: 1H")
    parser.add_argument("--history-days", type=int, default=None)
    args = parser.parse_args()

    cfg = load_config(args.config)
    base_url = cfg["exchange"]["base_url"]
    rps = cfg["exchange"].get("requests_per_second", 5)
    symbols = args.symbols or cfg["symbols"]
    bar = args.timeframe or cfg["timeframe"]
    history_days = args.history_days or cfg["history_days"]
    data_dir = cfg["data_dir"]

    limiter = RateLimiter(rps)

    print(f"Descargando {len(symbols)} símbolos | timeframe={bar} | history_days={history_days}")
    print(f"Guardando en: {os.path.abspath(data_dir)}\n")

    summary = []
    for symbol in symbols:
        try:
            path, n_rows = update_symbol_csv(base_url, symbol, bar, history_days, data_dir, limiter)
            summary.append((symbol, n_rows, path))
            print(f"  OK  {symbol:12s} -> {n_rows:6d} velas -> {path}")
        except Exception as e:
            print(f"  ERROR {symbol}: {e}")

    print("\nResumen:")
    for symbol, n_rows, path in summary:
        print(f"  {symbol:12s} {n_rows:6d} velas")


if __name__ == "__main__":
    main()
