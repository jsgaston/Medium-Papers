"""
backtester.py
=============
Carga los CSVs descargados por okx_downloader.py para todos los símbolos
configurados y ejecuta la estrategia sobre cada uno, devolviendo métricas
individuales y agregadas (media/mediana entre símbolos). Usar métricas
agregadas multi-símbolo para un mismo set de parámetros es lo que da
robustez real: un parámetro que solo funciona en BTC probablemente esté
sobreajustado, uno que funciona en 10-12 símbolos distintos es más fiable.
"""

import os
import glob
import pandas as pd
import numpy as np

from strategy import StrategyParams, run_backtest


def load_all_symbol_data(data_dir: str, timeframe: str) -> dict:
    """Devuelve {symbol: dataframe} para todos los CSV en data_dir que coincidan con el timeframe."""
    pattern = os.path.join(data_dir, f"*_{timeframe}.csv")
    data = {}
    for path in glob.glob(pattern):
        fname = os.path.basename(path)
        symbol = fname.replace(f"_{timeframe}.csv", "").replace("_", "-")
        df = pd.read_csv(path)
        if df.empty:
            continue
        df = df.sort_values("ts").reset_index(drop=True)
        data[symbol] = df
    return data


def backtest_multi_symbol(symbol_data: dict, params: StrategyParams, initial_capital: float) -> dict:
    """Ejecuta el backtest en todos los símbolos con el MISMO set de parámetros
    y agrega los resultados. Símbolos que fallen (datos insuficientes, etc.) se ignoran."""
    per_symbol = {}
    for symbol, df in symbol_data.items():
        try:
            result = run_backtest(df, params, initial_capital, symbol=symbol)
            per_symbol[symbol] = result
        except Exception:
            continue

    if not per_symbol:
        return None

    returns = [r.total_return_pct for r in per_symbol.values()]
    sharpes = [r.sharpe for r in per_symbol.values()]
    dds = [r.max_drawdown_pct for r in per_symbol.values()]
    trades = [r.trades for r in per_symbol.values()]
    pfs = [r.profit_factor for r in per_symbol.values() if np.isfinite(r.profit_factor)]

    return {
        "n_symbols": len(per_symbol),
        "mean_return_pct": float(np.mean(returns)),
        "median_return_pct": float(np.median(returns)),
        "worst_return_pct": float(np.min(returns)),
        "mean_sharpe": float(np.mean(sharpes)),
        "mean_max_drawdown_pct": float(np.mean(dds)),
        "worst_max_drawdown_pct": float(np.min(dds)),
        "mean_trades": float(np.mean(trades)),
        "mean_profit_factor": float(np.mean(pfs)) if pfs else 0.0,
        "per_symbol": per_symbol,
    }


if __name__ == "__main__":
    import yaml
    with open("config.yaml", "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    data = load_all_symbol_data(cfg["data_dir"], cfg["timeframe"])
    print(f"Símbolos cargados: {len(data)} -> {list(data.keys())}")

    if not data:
        print("No hay datos. Ejecuta primero: python okx_downloader.py --config config.yaml")
    else:
        params = StrategyParams(
            num_levels=3,
            price_deviation_multiplier=1.0,
            size_scaling_factor=0.15,
            base_order_size_pct=cfg["strategy"]["base_order_size_pct"],
            regrid_threshold=1.0,
            maker_fee=cfg["fees"]["maker"],
            taker_fee=cfg["fees"]["taker"],
            slippage_bps=cfg["backtest"]["slippage_bps"],
        )
        agg = backtest_multi_symbol(data, params, cfg["backtest"]["initial_capital_usdt"])
        print("\nResultado agregado (parámetros por defecto):")
        for k, v in agg.items():
            if k != "per_symbol":
                print(f"  {k}: {v}")
        print("\nPor símbolo:")
        for symbol, r in agg["per_symbol"].items():
            print(f"  {symbol:12s} ret={r.total_return_pct:7.2f}%  sharpe={r.sharpe:6.2f}  "
                  f"dd={r.max_drawdown_pct:7.2f}%  trades={r.trades:4d}")
