r"""
paper_trading_bot.py
=====================
Bot de paper trading en vivo: se conecta al feed público de tickers de OKX
(WebSocket, precio real en tiempo real) para todos los símbolos configurados
y aplica la MISMA lógica de grid-fibonacci ya validada en el backtest, pero
con dinero virtual — no envía ninguna orden real al exchange.

Diseñado para correr indefinidamente en el VPS (24/7, un mes o el tiempo que
quieras) y registra:
  - paper_trading_logs/trades.csv   -> cada fill simulado (compra/venta, PnL)
  - paper_trading_logs/equity.csv   -> snapshot de equity por símbolo cada N segundos
  - paper_trading_state/state.json  -> estado completo para poder reanudar si
                                        el proceso o el VPS se reinician

Uso:
    python paper_trading_bot.py --config paper_trading_config.yaml

Para pararlo de forma segura: Ctrl+C (guarda el estado antes de salir).

Para Windows Task Scheduler (mismo patrón que ya usas para tus EAs y el
recolector de order book):
    Programa: python.exe
    Argumentos: C:\ruta\okx_backtester\paper_trading_bot.py --config C:\ruta\okx_backtester\paper_trading_config.yaml
    Desencadenador: al iniciar el sistema (+ reintentar si falla)
"""

import argparse
import csv
import json
import os
import signal
import sys
import time
from collections import deque
from datetime import datetime, timezone

import numpy as np
import websocket
import yaml

from strategy import StrategyParams
from live_strategy import LiveGridState


def load_config(path):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def make_params(cfg) -> StrategyParams:
    sp = cfg["strategy"]
    return StrategyParams(
        num_levels=sp["num_levels"],
        price_deviation_multiplier=sp["price_deviation_multiplier"],
        size_scaling_factor=sp["size_scaling_factor"],
        base_order_size_pct=sp["base_order_size_pct"],
        regrid_threshold=sp["regrid_threshold"],
        maker_fee=sp["maker_fee"],
        taker_fee=sp["taker_fee"],
        slippage_bps=sp["slippage_bps"],
    )


class PaperTradingBot:
    def __init__(self, cfg):
        self.cfg = cfg
        self.symbols = cfg["symbols"]
        self.params = make_params(cfg)
        self.capital_per_symbol = cfg["capital_per_symbol_usdt"]
        self.state_dir = cfg["state_dir"]
        self.logs_dir = cfg["logs_dir"]
        self.equity_snapshot_interval = cfg["equity_snapshot_interval_sec"]
        self.state_save_interval = cfg["state_save_interval_sec"]

        os.makedirs(self.state_dir, exist_ok=True)
        os.makedirs(self.logs_dir, exist_ok=True)
        self.state_path = os.path.join(self.state_dir, "state.json")
        self.trades_path = os.path.join(self.logs_dir, "trades.csv")
        self.equity_path = os.path.join(self.logs_dir, "equity.csv")

        self.grids = {}  # symbol -> LiveGridState
        self.last_price_seen = {}
        self._last_equity_snapshot = 0.0
        self._last_state_save = 0.0
        self._started_at = None

        # --- para los resúmenes periódicos (PnL, Sharpe, ROI) ---
        self.summary_interval = cfg.get("summary_interval_sec", 3600)  # 1h por defecto
        self._last_summary = time.time()
        self.summary_log_path = os.path.join(self.logs_dir, "summary_log.csv")
        self._ensure_summary_log_header()
        # historial de equity en memoria (símbolo -> deque de (ts, equity)),
        # para calcular Sharpe sin tener que releer equity.csv entero cada vez.
        # Con snapshots cada equity_snapshot_interval_sec, 20000 puntos cubren
        # sobradamente varios meses de histórico.
        self.equity_history = {s: deque(maxlen=20000) for s in self.symbols}
        self.realized_pnl_total = {s: 0.0 for s in self.symbols}

        self._ensure_csv_headers()
        self._load_or_init_state()

    def _ensure_summary_log_header(self):
        if not os.path.exists(self.summary_log_path):
            with open(self.summary_log_path, "w", newline="", encoding="utf-8") as f:
                csv.writer(f).writerow(
                    ["datetime_utc", "symbol", "price", "equity", "roi_pct",
                     "realized_pnl", "sharpe", "n_trades"]
                )

    def _ensure_csv_headers(self):
        if not os.path.exists(self.trades_path):
            with open(self.trades_path, "w", newline="", encoding="utf-8") as f:
                csv.writer(f).writerow(
                    ["datetime_utc", "symbol", "side", "price", "qty", "fee", "realized_pnl"]
                )
        if not os.path.exists(self.equity_path):
            with open(self.equity_path, "w", newline="", encoding="utf-8") as f:
                csv.writer(f).writerow(
                    ["datetime_utc", "symbol", "price", "cash", "position_qty", "equity", "return_pct"]
                )

    def _load_or_init_state(self):
        if os.path.exists(self.state_path):
            with open(self.state_path, "r", encoding="utf-8") as f:
                saved = json.load(f)
            self._started_at = saved.get("started_at")
            for symbol in self.symbols:
                if symbol in saved.get("grids", {}):
                    self.grids[symbol] = LiveGridState.from_dict(saved["grids"][symbol], self.params)
            for symbol, pnl in saved.get("realized_pnl_total", {}).items():
                if symbol in self.realized_pnl_total:
                    self.realized_pnl_total[symbol] = pnl
            for symbol, hist in saved.get("equity_history_tail", {}).items():
                if symbol in self.equity_history:
                    self.equity_history[symbol].extend([tuple(p) for p in hist])
            print(f"Estado previo cargado desde {self.state_path} "
                  f"({len(self.grids)}/{len(self.symbols)} símbolos recuperados).")
        if self._started_at is None:
            self._started_at = datetime.now(timezone.utc).isoformat()
        # Los símbolos que falten (primera vez, o símbolo nuevo añadido después)
        # se inicializan en cuanto llegue su primer precio (ver on_ticker).

    def _save_state(self):
        data = {
            "started_at": self._started_at,
            "grids": {s: g.to_dict() for s, g in self.grids.items()},
            "realized_pnl_total": self.realized_pnl_total,
            # Solo guardamos la cola reciente del historial de equity (no las
            # 20000 entradas completas) para no hinchar el JSON de estado.
            "equity_history_tail": {s: list(h)[-500:] for s, h in self.equity_history.items()},
        }
        tmp_path = self.state_path + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp_path, self.state_path)

    def _log_trade(self, symbol, fill, now_iso):
        with open(self.trades_path, "a", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow([
                now_iso, symbol, fill.side, f"{fill.price:.8f}", f"{fill.qty:.8f}",
                f"{fill.fee:.6f}", "" if fill.realized_pnl is None else f"{fill.realized_pnl:.6f}",
            ])

    def _log_equity(self, symbol, grid, now_iso, now_ts):
        equity = grid.equity()
        ret_pct = (equity / grid.initial_capital - 1) * 100
        with open(self.equity_path, "a", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow([
                now_iso, symbol, f"{grid.last_price:.8f}", f"{grid.cash:.4f}",
                f"{grid.position_qty:.8f}", f"{equity:.4f}", f"{ret_pct:.4f}",
            ])
        self.equity_history[symbol].append((now_ts, equity))

    def on_ticker(self, symbol, price, ts_ms):
        now = time.time()
        now_iso = datetime.now(timezone.utc).isoformat()

        if symbol not in self.grids:
            self.grids[symbol] = LiveGridState(symbol, self.params, self.capital_per_symbol, price)
            print(f"  [{symbol}] grid inicializado a precio {price}")
            return  # el primer tick solo siembra el grid, no puede generar fill

        grid = self.grids[symbol]
        fills = grid.on_price_update(price, ts_ms / 1000.0)
        for fill in fills:
            self._log_trade(symbol, fill, now_iso)
            if fill.realized_pnl is not None:
                self.realized_pnl_total[symbol] += fill.realized_pnl
            pnl_txt = f" pnl={fill.realized_pnl:.4f}" if fill.realized_pnl is not None else ""
            print(f"  [{symbol}] {fill.side.upper()} {fill.qty:.6f} @ {fill.price:.4f}{pnl_txt}")

        if now - self._last_equity_snapshot >= self.equity_snapshot_interval:
            for s, g in self.grids.items():
                self._log_equity(s, g, now_iso, now)
            self._last_equity_snapshot = now

        if now - self._last_summary >= self.summary_interval:
            self.print_periodic_summary()
            self._last_summary = now

        if now - self._last_state_save >= self.state_save_interval:
            self._save_state()
            self._last_state_save = now

    def _compute_sharpe(self, symbol) -> float:
        hist = self.equity_history[symbol]
        if len(hist) < 3:
            return 0.0
        ts_arr = np.array([h[0] for h in hist], dtype=float)
        eq_arr = np.array([h[1] for h in hist], dtype=float)
        returns = np.diff(eq_arr) / eq_arr[:-1]
        if returns.std() == 0:
            return 0.0
        span_sec = max(ts_arr[-1] - ts_arr[0], 1e-6)
        snapshots_per_year = (len(hist) / span_sec) * 31_536_000  # segundos en un año
        return float((returns.mean() / returns.std()) * np.sqrt(snapshots_per_year))

    def print_periodic_summary(self):
        now_iso = datetime.now(timezone.utc).isoformat()
        print("\n" + "=" * 78)
        print(f"RESUMEN PERIÓDICO ({now_iso})")
        print("=" * 78)
        print(f"{'Símbolo':12s} {'Precio':>12s} {'Equity':>10s} {'ROI %':>8s} "
              f"{'PnL real.':>10s} {'Sharpe':>8s} {'Trades':>7s}")

        total_initial, total_equity = 0.0, 0.0
        with open(self.summary_log_path, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            for symbol, g in sorted(self.grids.items()):
                equity = g.equity()
                roi_pct = (equity / g.initial_capital - 1) * 100
                sharpe = self._compute_sharpe(symbol)
                pnl = self.realized_pnl_total[symbol]
                total_initial += g.initial_capital
                total_equity += equity

                print(f"{symbol:12s} {g.last_price:12.6f} {equity:10.2f} {roi_pct:8.2f} "
                      f"{pnl:10.4f} {sharpe:8.2f} {g.n_trades:7d}")
                writer.writerow([now_iso, symbol, f"{g.last_price:.8f}", f"{equity:.4f}",
                                  f"{roi_pct:.4f}", f"{pnl:.6f}", f"{sharpe:.4f}", g.n_trades])

        if total_initial > 0:
            total_roi = (total_equity / total_initial - 1) * 100
            print("-" * 78)
            print(f"{'TOTAL':12s} {'':>12s} {total_equity:10.2f} {total_roi:8.2f}")
        print("=" * 78 + "\n")


        print("\n--- Resumen actual (paper trading) ---")
        total_initial = 0.0
        total_equity = 0.0
        for symbol, g in sorted(self.grids.items()):
            eq = g.equity()
            ret = (eq / g.initial_capital - 1) * 100
            total_initial += g.initial_capital
            total_equity += eq
            print(f"  {symbol:12s} equity={eq:10.2f}  ret={ret:7.2f}%  trades={g.n_trades:4d}")
        if total_initial > 0:
            print(f"  {'TOTAL':12s} equity={total_equity:10.2f}  "
                  f"ret={(total_equity/total_initial-1)*100:7.2f}%")

    # --- WebSocket callbacks ---
    def on_open(self, ws):
        args = [{"channel": "tickers", "instId": s} for s in self.symbols]
        ws.send(json.dumps({"op": "subscribe", "args": args}))
        print(f"Suscrito a tickers para {len(self.symbols)} símbolos.\n")

    def on_message(self, ws, message):
        try:
            payload = json.loads(message)
        except json.JSONDecodeError:
            return
        if payload.get("event") == "error":
            print(f"  [WS ERROR] {payload}")
            return
        if payload.get("event") == "subscribe":
            return
        arg = payload.get("arg", {})
        symbol = arg.get("instId")
        if not symbol:
            return
        for item in payload.get("data", []):
            try:
                last_price = float(item["last"])
                ts_ms = int(item["ts"])
            except (KeyError, ValueError, TypeError):
                continue
            self.on_ticker(symbol, last_price, ts_ms)

    def on_error(self, ws, error):
        print(f"  [WS ERROR] {error}")

    def on_close(self, ws, code, msg):
        print(f"  [WS CLOSED] code={code} msg={msg}")
        self._save_state()

    def run_forever(self):
        while True:
            try:
                ws = websocket.WebSocketApp(
                    self.cfg["exchange"]["ws_public_url"],
                    on_open=self.on_open,
                    on_message=self.on_message,
                    on_error=self.on_error,
                    on_close=self.on_close,
                )
                ws.run_forever(ping_interval=20, ping_timeout=10)
            except Exception as e:
                print(f"  [FATAL] {e}")
            print("  Reconectando en 5s...")
            time.sleep(5)


def main():
    parser = argparse.ArgumentParser(description="Bot de paper trading en vivo para OKX")
    parser.add_argument("--config", default="paper_trading_config.yaml")
    args = parser.parse_args()

    cfg = load_config(args.config)
    bot = PaperTradingBot(cfg)

    def handle_sigint(signum, frame):
        print("\nSeñal de interrupción recibida, guardando estado antes de salir...")
        bot._save_state()
        bot.print_periodic_summary()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_sigint)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, handle_sigint)

    print(f"Paper trading iniciado | {len(bot.symbols)} símbolos | "
          f"{bot.capital_per_symbol} USDT virtuales por símbolo")
    print(f"Trades: {bot.trades_path}")
    print(f"Equity: {bot.equity_path}")
    print(f"Estado: {bot.state_path}\n")

    bot.run_forever()


if __name__ == "__main__":
    main()
