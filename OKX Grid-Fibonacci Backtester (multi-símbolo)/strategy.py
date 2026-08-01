"""
strategy.py
===========
Estrategia "Grid Fibonacci" adaptada del concepto de provisión de liquidez de
Raydium (niveles 23.6/38.2/50/61.8/78.6%) pero para un exchange centralizado
como OKX, donde en vez de "proveer liquidez a un AMM" colocamos órdenes límite
escalonadas alrededor del precio (grid trading clásico con espaciado Fibonacci
y tamaño creciente cuanto más lejos del precio, tal como en el PDF original).

Simulación basada en velas OHLC (no en order book real):
  - En cada vela, si low <= nivel_compra <= high -> se considera ejecutada la compra
  - Si high >= nivel_venta <= ... -> se considera ejecutada la venta
  - Al ejecutarse un nivel, se coloca automáticamente la orden opuesta (take-profit)
    un nivel de Fibonacci más allá, como en un grid bot clásico.
  - Si el precio se aleja demasiado del grid (más allá del nivel externo * regrid
    threshold), se cancela todo y se recentra un grid nuevo en el precio actual.

Esto es una aproximación razonable pero no idéntica a tener el order book real:
asume que si el precio de la vela toca el nivel, la orden se llena al precio del
nivel (menos slippage configurado). Para mayor precisión pueden usarse los
snapshots del recolector de order book (okx_ws_collector.py) una vez acumules
suficiente histórico propio.
"""

from dataclasses import dataclass, field
import numpy as np
import pandas as pd

FIB_RATIOS = [0.236, 0.382, 0.5, 0.618, 0.786, 1.0, 1.618]


@dataclass
class StrategyParams:
    num_levels: int = 3
    price_deviation_multiplier: float = 1.0
    size_scaling_factor: float = 0.15   # k: cuanto más lejos, mayor tamaño (Si = S*(1+k*i))
    base_order_size_pct: float = 0.02   # % del capital en la orden del nivel 1
    regrid_threshold: float = 1.0       # recentra si precio > nivel externo * este factor
    maker_fee: float = 0.0008
    taker_fee: float = 0.001
    slippage_bps: float = 2.0


@dataclass
class BacktestResult:
    symbol: str
    equity_curve: pd.Series
    trades: int
    total_return_pct: float
    max_drawdown_pct: float
    sharpe: float
    profit_factor: float
    win_rate: float
    final_equity: float


def _build_grid(center_price: float, params: StrategyParams, capital: float):
    """Construye niveles de compra/venta y tamaños, igual que el diagrama del PDF:
    'small orders near price, large orders further away'."""
    ratios = FIB_RATIOS[: params.num_levels]
    base_size_usdt = capital * params.base_order_size_pct

    buy_levels = []
    sell_levels = []
    for i, r in enumerate(ratios):
        dev = r * params.price_deviation_multiplier
        size_usdt = base_size_usdt * (1 + params.size_scaling_factor * i)
        buy_levels.append({"price": center_price * (1 - dev / 10), "size_usdt": size_usdt, "filled": False})
        sell_levels.append({"price": center_price * (1 + dev / 10), "size_usdt": size_usdt, "filled": False})
    return buy_levels, sell_levels


def run_backtest(df: pd.DataFrame, params: StrategyParams, initial_capital: float, symbol: str = "") -> BacktestResult:
    """
    df debe tener columnas: ts, open, high, low, close (ordenado ascendente por ts).
    """
    if df.empty or len(df) < 10:
        raise ValueError(f"Datos insuficientes para {symbol}")

    cash = initial_capital
    position_qty = 0.0  # en unidades del activo base
    equity_curve = []
    trade_pnls = []
    n_trades = 0
    slip = params.slippage_bps / 10000.0

    center_price = float(df.iloc[0]["open"])
    buy_levels, sell_levels = _build_grid(center_price, params, initial_capital)
    outer_ratio = FIB_RATIOS[params.num_levels - 1] * params.price_deviation_multiplier / 10

    for _, row in df.iterrows():
        low, high, close = float(row["low"]), float(row["high"]), float(row["close"])

        # --- comprobar fills de compra ---
        for lvl in buy_levels:
            if not lvl["filled"] and low <= lvl["price"] <= high:
                fill_price = lvl["price"] * (1 + slip)
                qty = lvl["size_usdt"] / fill_price
                cost = qty * fill_price
                fee = cost * params.taker_fee
                if cash >= cost + fee:
                    cash -= (cost + fee)
                    position_qty += qty
                    lvl["filled"] = True
                    n_trades += 1
                    # colocar take-profit de venta un nivel de fib más allá
                    tp_price = fill_price * (1 + FIB_RATIOS[0] * params.price_deviation_multiplier / 10)
                    sell_levels.append({"price": tp_price, "size_usdt": lvl["size_usdt"], "filled": False,
                                         "is_tp_for": fill_price})

        # --- comprobar fills de venta ---
        for lvl in sell_levels:
            if not lvl["filled"] and low <= lvl["price"] <= high and position_qty > 0:
                fill_price = lvl["price"] * (1 - slip)
                qty = min(lvl["size_usdt"] / fill_price, position_qty)
                if qty <= 0:
                    continue
                proceeds = qty * fill_price
                fee = proceeds * params.taker_fee
                cash += (proceeds - fee)
                position_qty -= qty
                lvl["filled"] = True
                n_trades += 1
                entry_price = lvl.get("is_tp_for", fill_price)
                trade_pnls.append((fill_price - entry_price) * qty - fee)

        # --- limpiar niveles llenos y re-centrar si hace falta ---
        buy_levels = [l for l in buy_levels if not l["filled"]]
        sell_levels = [l for l in sell_levels if not l["filled"]]

        if abs(close - center_price) / center_price > outer_ratio * params.regrid_threshold:
            center_price = close
            # IMPORTANTE: al re-centrar, hay que descartar las órdenes de grid
            # pendientes antiguas (ya no tienen sentido ancladas al precio viejo).
            # Solo conservamos los take-profit ("is_tp_for") que siguen abiertos
            # porque corresponden a posición REAL que aún hay que cerrar; el resto
            # eran órdenes "naked" sin inventario detrás. Sin este descarte, cada
            # re-centrado apila un grid nuevo sobre el anterior sin límite, e
            # infla artificialmente el número de trades (bug corregido).
            sell_levels = [l for l in sell_levels if "is_tp_for" in l]
            buy_levels = []
            new_buy, new_sell = _build_grid(center_price, params, cash + position_qty * close)
            buy_levels.extend(new_buy)
            sell_levels.extend(new_sell)

        equity = cash + position_qty * close
        equity_curve.append(equity)

    equity_series = pd.Series(equity_curve, index=df["ts"].values)
    returns = equity_series.pct_change().dropna()

    total_return_pct = (equity_series.iloc[-1] / initial_capital - 1) * 100
    running_max = equity_series.cummax()
    drawdown = (equity_series - running_max) / running_max
    max_dd_pct = drawdown.min() * 100

    if returns.std() > 0:
        periods_per_year = _infer_annualization_factor(df)
        sharpe = (returns.mean() / returns.std()) * np.sqrt(periods_per_year)
    else:
        sharpe = 0.0

    wins = [p for p in trade_pnls if p > 0]
    losses = [p for p in trade_pnls if p <= 0]
    profit_factor = (sum(wins) / abs(sum(losses))) if losses and sum(losses) != 0 else (float("inf") if wins else 0.0)
    win_rate = (len(wins) / len(trade_pnls) * 100) if trade_pnls else 0.0

    return BacktestResult(
        symbol=symbol,
        equity_curve=equity_series,
        trades=n_trades,
        total_return_pct=total_return_pct,
        max_drawdown_pct=max_dd_pct,
        sharpe=sharpe,
        profit_factor=profit_factor,
        win_rate=win_rate,
        final_equity=equity_series.iloc[-1],
    )


def _infer_annualization_factor(df: pd.DataFrame) -> float:
    """Estima cuántas velas caben en un año según el timeframe real de los datos."""
    if len(df) < 2:
        return 365.0
    delta_ms = float(df["ts"].iloc[1]) - float(df["ts"].iloc[0])
    delta_minutes = delta_ms / 1000 / 60
    if delta_minutes <= 0:
        return 365.0
    bars_per_day = (24 * 60) / delta_minutes
    return bars_per_day * 365
