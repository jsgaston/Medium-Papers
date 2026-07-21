"""
fetch_rates.py
--------------
Actualiza a diario el CSV que lee InterestRateEA.mq5 con los tipos de
interés oficiales de varios bancos centrales.

Fuentes automáticas (APIs gratuitas):
  - FED  (USD) -> FRED API           (necesita API key gratis: https://fred.stlouisfed.org/docs/api/api_key.html)
  - ECB  (EUR) -> ECB Data Portal SDW API (sin key)
  - BOC  (CAD) -> Bank of Canada Valet API (sin key)

Bancos SIN api pública sencilla y gratuita (BOJ, SNB, RBA, RBNZ, BOE):
  se rellenan a mano en el diccionario MANUAL_RATES de más abajo cada vez
  que cambien (el script se encarga de detectar el cambio y anotar
  HIKE/CUT/HOLD igualmente). BOE sí tiene API pero requiere registro;
  si te merece la pena, la añadimos luego con el mismo patrón que el BOC.

IMPORTANTE: los endpoints y series de estas APIs pueden cambiar. Antes de
dejarlo en un Task Scheduler desatendido, ejecútalo una vez a mano y revisa
el CSV generado.

Uso:
    python fetch_rates.py

Programarlo a diario (Windows Task Scheduler) o en cron:
    0 22 * * *  python /ruta/fetch_rates.py
"""

import csv
import os
import sys
from datetime import date, datetime

try:
    import requests
except ImportError:
    sys.exit("Falta 'requests'. Instala con: pip install requests")

# ---------------------------------------------------------------------
# CONFIGURACIÓN
# ---------------------------------------------------------------------

# Ruta al CSV que lee el EA. Debe coincidir con InpFileName del EA.
# Si InpUseCommon=true en el EA, esta ruta normalmente es:
#   Windows: C:\Users\<user>\AppData\Roaming\MetaQuotes\Terminal\Common\Files\interest_rates.csv
CSV_PATH = os.environ.get(
    "IR_CSV_PATH",
    r"C:\Users\Public\Documents\MetaQuotes\Terminal\Common\Files\interest_rates.csv",
)

# Clave gratuita de FRED (regístrate en https://fred.stlouisfed.org/docs/api/api_key.html)
FRED_API_KEY = os.environ.get("FRED_API_KEY", "TU_API_KEY_FRED")

# Bancos sin API gratuita sencilla: actualiza aquí el tipo vigente cuando cambie.
# El script compara este valor contra el último registrado en el CSV para
# decidir si es HIKE, CUT o HOLD.
MANUAL_RATES = {
    "BOJ": {"currency": "JPY", "rate": 0.75},
    "SNB": {"currency": "CHF", "rate": 0.25},
    "RBA": {"currency": "AUD", "rate": 4.10},
    "RBNZ": {"currency": "NZD", "rate": 3.25},
    "BOE": {"currency": "GBP", "rate": 4.75},
}

FIELDNAMES = ["Date", "Bank", "Currency", "Rate", "PrevRate", "Action"]


# ---------------------------------------------------------------------
# FUENTES AUTOMÁTICAS
# ---------------------------------------------------------------------

def fetch_fed_rate():
    """Límite superior del rango objetivo de Fed Funds (serie DFEDTARU)."""
    url = (
        "https://api.stlouisfed.org/fred/series/observations"
        f"?series_id=DFEDTARU&api_key={FRED_API_KEY}&file_type=json"
        "&sort_order=desc&limit=1"
    )
    r = requests.get(url, timeout=15)
    r.raise_for_status()
    obs = r.json()["observations"][0]
    return float(obs["value"])


def fetch_ecb_rate():
    """Tipo de la facilidad de refinanciación principal (Main Refinancing Rate)."""
    url = (
        "https://data-api.ecb.europa.eu/service/data/FM/"
        "D.U2.EUR.4F.KR.MRR_FR.LEV?lastNObservations=1&format=jsondata"
    )
    r = requests.get(url, timeout=15, headers={"Accept": "application/json"})
    r.raise_for_status()
    data = r.json()
    series = data["dataSets"][0]["series"]
    first_key = next(iter(series))
    obs = series[first_key]["observations"]
    last_idx = max(int(k) for k in obs.keys())
    return float(obs[str(last_idx)][0])


def fetch_boc_rate():
    """Overnight rate target del Banco de Canadá (Valet API)."""
    # Si el nombre de la serie ha cambiado, consultar:
    # https://www.bankofcanada.ca/valet-api-how-to/
    for series_name in ("CBC20210", "V39079"):
        try:
            url = f"https://www.bankofcanada.ca/valet/observations/{series_name}/json?recent=1"
            r = requests.get(url, timeout=15)
            r.raise_for_status()
            data = r.json()
            obs = data["observations"][-1]
            value = list(obs.values())
            # el primer campo es "d" (fecha); el segundo es el dict con el valor
            for k, v in obs.items():
                if k != "d":
                    return float(v["v"])
        except Exception:
            continue
    raise RuntimeError("No se pudo obtener el tipo del BOC (revisar nombre de serie)")


AUTO_SOURCES = {
    "FED": ("USD", fetch_fed_rate),
    "ECB": ("EUR", fetch_ecb_rate),
    "BOC": ("CAD", fetch_boc_rate),
}


# ---------------------------------------------------------------------
# LÓGICA DE CSV
# ---------------------------------------------------------------------

def load_last_rates(path):
    """Devuelve {bank: last_rate} leyendo el histórico existente."""
    last = {}
    if not os.path.exists(path):
        return last
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            last[row["Bank"]] = float(row["Rate"])
    return last


def classify(prev_rate, new_rate):
    if prev_rate is None:
        return "HOLD"
    if new_rate > prev_rate:
        return "HIKE"
    if new_rate < prev_rate:
        return "CUT"
    return "HOLD"


def append_rows(path, rows):
    file_exists = os.path.exists(path)
    os.makedirs(os.path.dirname(path), exist_ok=True) if os.path.dirname(path) else None
    with open(path, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        if not file_exists:
            writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main():
    today_str = date.today().strftime("%Y.%m.%d")
    last_rates = load_last_rates(CSV_PATH)
    new_rows = []

    # --- fuentes automáticas ---
    for bank, (currency, fetch_fn) in AUTO_SOURCES.items():
        try:
            rate = fetch_fn()
        except Exception as e:
            print(f"[AVISO] No se pudo obtener {bank}: {e}")
            continue
        prev = last_rates.get(bank)
        action = classify(prev, rate)
        new_rows.append({
            "Date": today_str,
            "Bank": bank,
            "Currency": currency,
            "Rate": f"{rate:.2f}",
            "PrevRate": f"{prev:.2f}" if prev is not None else f"{rate:.2f}",
            "Action": action,
        })
        print(f"{bank}: {rate:.2f}% ({action})")

    # --- fuentes manuales ---
    for bank, info in MANUAL_RATES.items():
        rate = info["rate"]
        currency = info["currency"]
        prev = last_rates.get(bank)
        action = classify(prev, rate)
        new_rows.append({
            "Date": today_str,
            "Bank": bank,
            "Currency": currency,
            "Rate": f"{rate:.2f}",
            "PrevRate": f"{prev:.2f}" if prev is not None else f"{rate:.2f}",
            "Action": action,
        })
        print(f"{bank}: {rate:.2f}% ({action}) [manual]")

    if new_rows:
        append_rows(CSV_PATH, new_rows)
        print(f"\nEscritas {len(new_rows)} filas en {CSV_PATH}")
    else:
        print("No se ha escrito nada (ninguna fuente respondió).")


if __name__ == "__main__":
    main()
