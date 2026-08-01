"""
grid_search.py
==============
Grid search clásico (como el descrito en el PDF de Raydium) pero aplicado a la
estrategia Grid-Fibonacci sobre datos reales de OKX, multi-símbolo.

Para cada combinación de (num_levels, price_deviation_multiplier,
size_scaling_factor, regrid_threshold):
  1. Se corre el backtest en TODOS los símbolos cargados
  2. Se agregan las métricas (media, mediana, peor caso entre símbolos)
  3. Se guarda todo en results/grid_search_results.csv
  4. Se generan heatmaps 2D (num_levels x price_deviation_multiplier) para
     cada valor de size_scaling_factor, coloreados por Sharpe medio.

Uso:
    python grid_search.py --config config.yaml
    python grid_search.py --config config.yaml --metric mean_return_pct
    python grid_search.py --config config.yaml --workers 8
"""

import argparse
import itertools
import os
import time
from multiprocessing import Pool, cpu_count

import pandas as pd
import yaml
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from strategy import StrategyParams
from backtester import load_all_symbol_data, backtest_multi_symbol

# Variable global para que cada worker de multiprocessing tenga acceso a los
# datos ya cargados sin tener que releerlos del disco en cada combinación.
_SYMBOL_DATA = None
_CFG = None


def _init_worker(symbol_data, cfg):
    global _SYMBOL_DATA, _CFG
    _SYMBOL_DATA = symbol_data
    _CFG = cfg


def _evaluate_combo(combo):
    num_levels, dev_mult, size_scale, regrid_th = combo
    params = StrategyParams(
        num_levels=num_levels,
        price_deviation_multiplier=dev_mult,
        size_scaling_factor=size_scale,
        base_order_size_pct=_CFG["strategy"]["base_order_size_pct"],
        regrid_threshold=regrid_th,
        maker_fee=_CFG["fees"]["maker"],
        taker_fee=_CFG["fees"]["taker"],
        slippage_bps=_CFG["backtest"]["slippage_bps"],
    )
    agg = backtest_multi_symbol(_SYMBOL_DATA, params, _CFG["backtest"]["initial_capital_usdt"])
    if agg is None:
        return None

    row = {
        "num_levels": num_levels,
        "price_deviation_multiplier": dev_mult,
        "size_scaling_factor": size_scale,
        "regrid_threshold": regrid_th,
        "n_symbols": agg["n_symbols"],
        "mean_return_pct": agg["mean_return_pct"],
        "median_return_pct": agg["median_return_pct"],
        "worst_return_pct": agg["worst_return_pct"],
        "mean_sharpe": agg["mean_sharpe"],
        "mean_max_drawdown_pct": agg["mean_max_drawdown_pct"],
        "worst_max_drawdown_pct": agg["worst_max_drawdown_pct"],
        "mean_trades": agg["mean_trades"],
        "mean_profit_factor": agg["mean_profit_factor"],
    }
    return row


def run_grid_search(cfg: dict, workers: int) -> pd.DataFrame:
    symbol_data = load_all_symbol_data(cfg["data_dir"], cfg["timeframe"])
    if not symbol_data:
        raise RuntimeError(
            "No hay datos descargados. Ejecuta primero: python okx_downloader.py --config config.yaml"
        )
    print(f"Símbolos cargados para el grid search: {len(symbol_data)}")

    sp = cfg["strategy"]
    combos = list(itertools.product(
        sp["num_levels_grid"],
        sp["price_deviation_multiplier_grid"],
        sp["size_scaling_factor_grid"],
        sp["regrid_threshold_grid"],
    ))
    print(f"Total de combinaciones a evaluar: {len(combos)} x {len(symbol_data)} símbolos")

    t0 = time.time()
    results = []
    with Pool(processes=workers, initializer=_init_worker, initargs=(symbol_data, cfg)) as pool:
        for i, row in enumerate(pool.imap_unordered(_evaluate_combo, combos), 1):
            if row is not None:
                results.append(row)
            if i % max(1, len(combos) // 20) == 0:
                print(f"  progreso: {i}/{len(combos)} ({time.time()-t0:.0f}s)")

    df = pd.DataFrame(results)
    return df


def save_heatmaps(df: pd.DataFrame, metric: str, results_dir: str):
    os.makedirs(results_dir, exist_ok=True)
    for regrid_th in sorted(df["regrid_threshold"].unique()):
        for size_scale in sorted(df["size_scaling_factor"].unique()):
            subset = df[(df["regrid_threshold"] == regrid_th) & (df["size_scaling_factor"] == size_scale)]
            if subset.empty:
                continue
            pivot = subset.pivot(index="price_deviation_multiplier", columns="num_levels", values=metric)

            fig, ax = plt.subplots(figsize=(6, 5))
            im = ax.imshow(pivot.values, cmap="RdYlGn", aspect="auto")
            ax.set_xticks(range(len(pivot.columns)))
            ax.set_xticklabels(pivot.columns)
            ax.set_yticks(range(len(pivot.index)))
            ax.set_yticklabels(pivot.index)
            ax.set_xlabel("num_levels")
            ax.set_ylabel("price_deviation_multiplier")
            ax.set_title(f"{metric}\nsize_scaling_factor={size_scale}, regrid_threshold={regrid_th}")

            for i in range(pivot.shape[0]):
                for j in range(pivot.shape[1]):
                    val = pivot.values[i, j]
                    if pd.notna(val):
                        ax.text(j, i, f"{val:.1f}", ha="center", va="center", fontsize=8)

            fig.colorbar(im, ax=ax)
            fname = os.path.join(
                results_dir,
                f"heatmap_{metric}_scale{size_scale}_regrid{regrid_th}.png".replace(" ", "")
            )
            fig.tight_layout()
            fig.savefig(fname, dpi=120)
            plt.close(fig)
            print(f"  Guardado: {fname}")


def main():
    parser = argparse.ArgumentParser(description="Grid search multi-símbolo para la estrategia Grid-Fibonacci en OKX")
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--metric", default="mean_sharpe",
                         choices=["mean_sharpe", "mean_return_pct", "median_return_pct",
                                  "worst_return_pct", "mean_profit_factor"])
    parser.add_argument("--workers", type=int, default=max(1, cpu_count() - 1))
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    results_dir = cfg.get("results_dir", "results")
    os.makedirs(results_dir, exist_ok=True)

    df = run_grid_search(cfg, workers=args.workers)
    if df.empty:
        print("El grid search no produjo resultados válidos (revisa los datos descargados).")
        return

    out_csv = os.path.join(results_dir, "grid_search_results.csv")
    df.sort_values(args.metric, ascending=False).to_csv(out_csv, index=False)
    print(f"\nResultados completos guardados en: {out_csv}")

    print(f"\nTop 10 combinaciones por {args.metric}:")
    top10 = df.sort_values(args.metric, ascending=False).head(10)
    cols = ["num_levels", "price_deviation_multiplier", "size_scaling_factor", "regrid_threshold",
            "mean_return_pct", "mean_sharpe", "mean_max_drawdown_pct", "worst_return_pct", "mean_trades"]
    print(top10[cols].to_string(index=False))

    print("\nGenerando heatmaps...")
    save_heatmaps(df, args.metric, results_dir)
    print("\nListo.")


if __name__ == "__main__":
    main()
