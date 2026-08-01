"""
run_pipeline.py
================
Orquesta todo el flujo en un solo comando:
  1. Descarga/actualiza histórico OHLCV multi-símbolo
  2. Corre el grid search completo
  3. Imprime el top de combinaciones

Pensado para programarlo en el VPS (Windows Task Scheduler) para que se
re-ejecute, por ejemplo, cada noche y vayas teniendo el ranking de parámetros
actualizado con datos frescos.

Uso:
    python run_pipeline.py --config config.yaml
    python run_pipeline.py --config config.yaml --skip-download   (si ya tienes los CSV al día)
"""

import argparse
import subprocess
import sys


def run(cmd):
    print(f"\n$ {' '.join(cmd)}\n")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"[ERROR] El comando falló con código {result.returncode}: {' '.join(cmd)}")
        sys.exit(result.returncode)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.yaml")
    parser.add_argument("--skip-download", action="store_true")
    parser.add_argument("--metric", default="mean_sharpe")
    parser.add_argument("--workers", type=int, default=None)
    args = parser.parse_args()

    python = sys.executable

    if not args.skip_download:
        run([python, "okx_downloader.py", "--config", args.config])
    else:
        print("Saltando descarga (--skip-download).")

    gs_cmd = [python, "grid_search.py", "--config", args.config, "--metric", args.metric]
    if args.workers:
        gs_cmd += ["--workers", str(args.workers)]
    run(gs_cmd)

    print("\nPipeline completo. Revisa la carpeta 'results/' para el CSV y los heatmaps.")


if __name__ == "__main__":
    main()
