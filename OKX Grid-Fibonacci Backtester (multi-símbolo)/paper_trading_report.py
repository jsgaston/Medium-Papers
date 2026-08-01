"""
paper_trading_report.py
========================
Lee los CSV generados por paper_trading_bot.py (trades.csv, equity.csv) y
genera un resumen de rendimiento: retorno por símbolo, Sharpe, máximo
drawdown, win rate, profit factor, y un gráfico de las curvas de equity.

Ejecútalo en cualquier momento (no hace falta parar el bot) para ver cómo va
el mes de paper trading.

Uso:
    python paper_trading_report.py --config paper_trading_config.yaml
"""

import argparse
import os

import numpy as np
import pandas as pd
import yaml
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def compute_metrics(equity_df: pd.DataFrame, initial_capital: float) -> dict:
    equity_df = equity_df.sort_values("datetime_utc")
    equity = equity_df["equity"].astype(float)
    if len(equity) < 2:
        return None

    returns = equity.pct_change().dropna()
    running_max = equity.cummax()
    drawdown = (equity - running_max) / running_max

    dt = pd.to_datetime(equity_df["datetime_utc"])
    span_days = max((dt.iloc[-1] - dt.iloc[0]).total_seconds() / 86400, 1e-6)
    snapshots_per_day = len(equity) / span_days
    periods_per_year = snapshots_per_day * 365

    sharpe = (returns.mean() / returns.std()) * np.sqrt(periods_per_year) if returns.std() > 0 else 0.0

    return {
        "days_running": span_days,
        "start_equity": float(equity.iloc[0]),
        "end_equity": float(equity.iloc[-1]),
        "total_return_pct": float((equity.iloc[-1] / initial_capital - 1) * 100),
        "max_drawdown_pct": float(drawdown.min() * 100),
        "sharpe": float(sharpe),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="paper_trading_config.yaml")
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    logs_dir = cfg["logs_dir"]
    trades_path = os.path.join(logs_dir, "trades.csv")
    equity_path = os.path.join(logs_dir, "equity.csv")

    if not os.path.exists(equity_path):
        print(f"No se encuentra {equity_path} todavía. ¿Ya arrancaste paper_trading_bot.py?")
        return

    equity_df = pd.read_csv(equity_path)
    trades_df = pd.read_csv(trades_path) if os.path.exists(trades_path) else pd.DataFrame()

    initial_capital = cfg["capital_per_symbol_usdt"]

    print("=" * 70)
    print("RESUMEN DE PAPER TRADING")
    print("=" * 70)

    fig, ax = plt.subplots(figsize=(10, 6))
    total_return_weighted = []

    for symbol in sorted(equity_df["symbol"].unique()):
        sub = equity_df[equity_df["symbol"] == symbol]
        metrics = compute_metrics(sub, initial_capital)
        if metrics is None:
            continue

        sym_trades = trades_df[trades_df["symbol"] == symbol] if not trades_df.empty else pd.DataFrame()
        closed = sym_trades[sym_trades["side"] == "sell"] if not sym_trades.empty else pd.DataFrame()
        n_trades = len(sym_trades)
        if not closed.empty and "realized_pnl" in closed.columns:
            pnls = closed["realized_pnl"].dropna().astype(float)
            wins = pnls[pnls > 0]
            losses = pnls[pnls <= 0]
            win_rate = (len(wins) / len(pnls) * 100) if len(pnls) else 0.0
            profit_factor = (wins.sum() / abs(losses.sum())) if losses.sum() != 0 and len(losses) else float("inf")
        else:
            win_rate, profit_factor = 0.0, 0.0

        print(f"\n{symbol}")
        print(f"  Días corriendo:      {metrics['days_running']:.1f}")
        print(f"  Equity inicial:      {metrics['start_equity']:.2f}")
        print(f"  Equity actual:       {metrics['end_equity']:.2f}")
        print(f"  Retorno total:       {metrics['total_return_pct']:.2f}%")
        print(f"  Máximo drawdown:     {metrics['max_drawdown_pct']:.2f}%")
        print(f"  Sharpe (anualizado): {metrics['sharpe']:.2f}")
        print(f"  Nº de trades:        {n_trades}")
        print(f"  Win rate:            {win_rate:.1f}%")
        print(f"  Profit factor:       {profit_factor:.2f}")

        total_return_weighted.append(metrics["total_return_pct"])

        dt = pd.to_datetime(sub["datetime_utc"])
        ax.plot(dt, sub["equity"].astype(float) / initial_capital * 100, label=symbol)

    if total_return_weighted:
        print(f"\n{'='*70}")
        print(f"Retorno medio entre símbolos: {np.mean(total_return_weighted):.2f}%")
        print(f"Peor símbolo:                 {np.min(total_return_weighted):.2f}%")
        print(f"Mejor símbolo:                {np.max(total_return_weighted):.2f}%")

    ax.set_title("Paper trading — equity normalizada (base 100) por símbolo")
    ax.set_ylabel("Equity (base 100)")
    ax.axhline(100, color="gray", linestyle="--", linewidth=0.8)
    ax.legend(fontsize=8, ncol=2)
    fig.tight_layout()
    out_png = os.path.join(logs_dir, "equity_curves.png")
    fig.savefig(out_png, dpi=120)
    print(f"\nGráfico guardado en: {out_png}")


if __name__ == "__main__":
    main()
