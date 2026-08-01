r"""
okx_ws_collector.py
====================
OKX NO ofrece histórico de order book (L2) gratuito más allá de unos meses
(y solo vía proveedores de pago como Tardis.dev o Amberdata). Como tu VPS está
encendido 24/7, este script construye tu PROPIO histórico de profundidad de
mercado desde ya, suscribiéndose al canal público `books5` (top 5 niveles bid/
ask) de OKX vía WebSocket para todos los símbolos configurados, y guardando
snapshots periódicos en CSV (uno por símbolo y día, para no crear ficheros
gigantes).

Pensado para correr en segundo plano de forma indefinida en el VPS (igual que
ya haces con tus EAs de MT5 vía Task Scheduler). Reconecta automáticamente si
se cae la conexión.

Uso:
    python okx_ws_collector.py --config config.yaml

Para Windows Task Scheduler (mismo patrón que ya usas para tus EAs):
    Programa: python.exe
    Argumentos: C:\ruta\okx_backtester\okx_ws_collector.py --config C:\ruta\okx_backtester\config.yaml
    Desencadenador: Al iniciar el sistema (+ reintentar si falla)
"""

import argparse
import csv
import json
import os
import threading
import time
from datetime import datetime, timezone

import websocket
import yaml

OKX_PUBLIC_WS = "wss://ws.okx.com:8443/ws/v5/public"


class OrderBookCollector:
    def __init__(self, symbols, channel, snapshot_every_sec, out_dir):
        self.symbols = symbols
        self.channel = channel
        self.snapshot_every_sec = snapshot_every_sec
        self.out_dir = out_dir
        self._last_written = {s: 0.0 for s in symbols}
        os.makedirs(out_dir, exist_ok=True)

    def _file_for(self, symbol):
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        safe_symbol = symbol.replace("-", "_")
        path = os.path.join(self.out_dir, f"{safe_symbol}_{day}.csv")
        is_new = not os.path.exists(path)
        return path, is_new

    def _write_snapshot(self, symbol, data):
        now = time.time()
        if now - self._last_written.get(symbol, 0) < self.snapshot_every_sec:
            return
        self._last_written[symbol] = now

        path, is_new = self._file_for(symbol)
        bids = data.get("bids", [])
        asks = data.get("asks", [])
        ts = data.get("ts")

        with open(path, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            if is_new:
                header = ["ts"]
                for i in range(len(bids)):
                    header += [f"bid_px_{i+1}", f"bid_sz_{i+1}"]
                for i in range(len(asks)):
                    header += [f"ask_px_{i+1}", f"ask_sz_{i+1}"]
                writer.writerow(header)
            row = [ts]
            for b in bids:
                row += [b[0], b[1]]
            for a in asks:
                row += [a[0], a[1]]
            writer.writerow(row)

    def on_message(self, ws, message):
        try:
            payload = json.loads(message)
        except json.JSONDecodeError:
            return
        if payload.get("event") in ("subscribe", "error"):
            if payload.get("event") == "error":
                print(f"  [WS ERROR] {payload}")
            return
        arg = payload.get("arg", {})
        symbol = arg.get("instId")
        for item in payload.get("data", []):
            self._write_snapshot(symbol, item)

    def on_open(self, ws):
        args = [{"channel": self.channel, "instId": s} for s in self.symbols]
        sub_msg = {"op": "subscribe", "args": args}
        ws.send(json.dumps(sub_msg))
        print(f"Suscrito a {self.channel} para {len(self.symbols)} símbolos.")

    def on_error(self, ws, error):
        print(f"  [WS ERROR] {error}")

    def on_close(self, ws, close_status_code, close_msg):
        print(f"  [WS CLOSED] code={close_status_code} msg={close_msg}")

    def run_forever(self):
        # Ping cada 20s como recomienda OKX para mantener viva la conexión
        while True:
            try:
                ws = websocket.WebSocketApp(
                    OKX_PUBLIC_WS,
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
    parser = argparse.ArgumentParser(description="Recolector continuo de order book (OKX) para histórico propio")
    parser.add_argument("--config", default="config.yaml")
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    symbols = cfg["symbols"]
    ob_cfg = cfg.get("orderbook_collector", {})
    channel = ob_cfg.get("channel", "books5")
    snapshot_every_sec = ob_cfg.get("snapshot_every_sec", 5)
    out_dir = cfg.get("orderbook_dir", "data/orderbook_snapshots")

    print(f"Iniciando recolector de order book | símbolos={len(symbols)} | canal={channel} | "
          f"cada {snapshot_every_sec}s | guardando en {os.path.abspath(out_dir)}")
    print("Este proceso corre indefinidamente. Déjalo encendido en el VPS (Ctrl+C para parar manualmente).\n")

    collector = OrderBookCollector(symbols, channel, snapshot_every_sec, out_dir)
    collector.run_forever()


if __name__ == "__main__":
    main()
