"""
live_strategy.py
=================
Adapta la lógica de `strategy.py` (backtest sobre velas OHLC) a un flujo de
precios en tiempo real (tick a tick), para el paper trading en vivo.

En vez de comprobar "low <= nivel <= high" de una vela, aquí comprobamos si el
nivel quedó cruzado entre el precio anterior y el precio actual (equivalente
conceptualmente, pero con la granularidad real del mercado en vez de la
aproximación de una vela agregada).

Reutiliza intencionadamente las mismas funciones (_build_grid, FIB_RATIOS) que
el backtester para que la lógica de decisión sea IDÉNTICA en backtest y en
paper trading — así el mes de paper trading es una validación real de lo que
ya viste en el grid search, no una estrategia distinta.
"""

import time
from dataclasses import dataclass, field
from typing import Optional

from strategy import StrategyParams, FIB_RATIOS, _build_grid


@dataclass
class Fill:
    symbol: str
    side: str          # "buy" o "sell"
    price: float
    qty: float
    fee: float
    realized_pnl: Optional[float]
    timestamp: float


class LiveGridState:
    """Estado de un grid en vivo para UN símbolo. Se actualiza con cada nuevo precio."""

    def __init__(self, symbol: str, params: StrategyParams, initial_capital: float, starting_price: float):
        self.symbol = symbol
        self.params = params
        self.initial_capital = initial_capital
        self.cash = initial_capital
        self.position_qty = 0.0
        self.center_price = starting_price
        self.last_price = starting_price
        self.buy_levels, self.sell_levels = _build_grid(starting_price, params, initial_capital)
        self.n_trades = 0
        self.outer_ratio = FIB_RATIOS[params.num_levels - 1] * params.price_deviation_multiplier / 10

    def to_dict(self):
        return {
            "symbol": self.symbol,
            "cash": self.cash,
            "position_qty": self.position_qty,
            "center_price": self.center_price,
            "last_price": self.last_price,
            "buy_levels": self.buy_levels,
            "sell_levels": self.sell_levels,
            "n_trades": self.n_trades,
            "initial_capital": self.initial_capital,
        }

    @classmethod
    def from_dict(cls, d, params: StrategyParams):
        obj = cls.__new__(cls)
        obj.symbol = d["symbol"]
        obj.params = params
        obj.initial_capital = d["initial_capital"]
        obj.cash = d["cash"]
        obj.position_qty = d["position_qty"]
        obj.center_price = d["center_price"]
        obj.last_price = d["last_price"]
        obj.buy_levels = d["buy_levels"]
        obj.sell_levels = d["sell_levels"]
        obj.n_trades = d["n_trades"]
        obj.outer_ratio = FIB_RATIOS[params.num_levels - 1] * params.price_deviation_multiplier / 10
        return obj

    def equity(self) -> float:
        return self.cash + self.position_qty * self.last_price

    def on_price_update(self, price: float, ts: float) -> list:
        """Procesa un nuevo precio. Devuelve la lista de Fill ocurridos (puede estar vacía)."""
        fills = []
        prev_price = self.last_price
        lo, hi = (prev_price, price) if prev_price <= price else (price, prev_price)
        slip = self.params.slippage_bps / 10000.0

        for lvl in self.buy_levels:
            if not lvl["filled"] and lo <= lvl["price"] <= hi:
                fill_price = lvl["price"] * (1 + slip)
                qty = lvl["size_usdt"] / fill_price
                cost = qty * fill_price
                fee = cost * self.params.taker_fee
                if self.cash >= cost + fee:
                    self.cash -= (cost + fee)
                    self.position_qty += qty
                    lvl["filled"] = True
                    self.n_trades += 1
                    tp_price = fill_price * (1 + FIB_RATIOS[0] * self.params.price_deviation_multiplier / 10)
                    self.sell_levels.append({"price": tp_price, "size_usdt": lvl["size_usdt"], "filled": False,
                                              "is_tp_for": fill_price})
                    fills.append(Fill(self.symbol, "buy", fill_price, qty, fee, None, ts))

        for lvl in self.sell_levels:
            if not lvl["filled"] and lo <= lvl["price"] <= hi and self.position_qty > 0:
                fill_price = lvl["price"] * (1 - slip)
                qty = min(lvl["size_usdt"] / fill_price, self.position_qty)
                if qty <= 0:
                    continue
                proceeds = qty * fill_price
                fee = proceeds * self.params.taker_fee
                self.cash += (proceeds - fee)
                self.position_qty -= qty
                lvl["filled"] = True
                self.n_trades += 1
                entry_price = lvl.get("is_tp_for", fill_price)
                realized_pnl = (fill_price - entry_price) * qty - fee
                fills.append(Fill(self.symbol, "sell", fill_price, qty, fee, realized_pnl, ts))

        self.buy_levels = [l for l in self.buy_levels if not l["filled"]]
        self.sell_levels = [l for l in self.sell_levels if not l["filled"]]

        if abs(price - self.center_price) / self.center_price > self.outer_ratio * self.params.regrid_threshold:
            self.center_price = price
            self.sell_levels = [l for l in self.sell_levels if "is_tp_for" in l]
            new_buy, new_sell = _build_grid(self.center_price, self.params, self.equity())
            self.buy_levels = new_buy
            self.sell_levels.extend(new_sell)

        self.last_price = price
        return fills
