"""
AI Night Guardian - materialitza el dataset final
====================================================

Llegeix manifest_corregit.csv i copia NOMES els fitxers marcats
keep_for_training=True cap a una estructura de carpetes per classe,
llesta per arrossegar/pujar a Edge Impulse Studio.

Execucio (des de la carpeta AI-Night-Guardian-main, on hi ha
dataset_final_16khz/ i manifest_corregit.csv):

    python materialize_dataset.py

Genera:
    dataset_ready/
        tos/*.wav
        crit_ajuda/*.wav
        caiguda_cop/*.wav
        plor_angoixa/*.wav
        roncs/*.wav
        silenci_ambient/*.wav
        context_normal/*.wav
        soroll_domestic/*.wav

Es pot re-executar sense perill: si dataset_ready ja existeix, nomes
afegeix/sobreescriu els fitxers, no esborra res per si sol.
"""

import csv
import shutil
import sys
from pathlib import Path
from collections import Counter

MANIFEST_PATH = sys.argv[1] if len(sys.argv) > 1 else "manifest_corregit.csv"
OUTPUT_DIR = Path(sys.argv[2] if len(sys.argv) > 2 else "dataset_ready")
DATASET_ROOT = Path(".")  # les rutes del manifest son relatives a aqui


def main():
    OUTPUT_DIR.mkdir(exist_ok=True)

    copied = Counter()
    missing = []
    skipped_not_kept = 0

    with open(MANIFEST_PATH, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row["keep_for_training"] != "True":
                skipped_not_kept += 1
                continue

            src = DATASET_ROOT / row["filepath"]
            final_label = row["final_label"]
            dest_dir = OUTPUT_DIR / final_label
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest = dest_dir / src.name

            try:
                shutil.copy2(src, dest)
                copied[final_label] += 1
            except FileNotFoundError:
                missing.append(str(src))

    print(f"Fitxers copiats: {sum(copied.values())}")
    for label, n in copied.most_common():
        print(f"  {label}: {n}")
    print(f"\nFilats (keep_for_training=False, ja exclosos abans): {skipped_not_kept}")

    if missing:
        print(f"\nAVIS: {len(missing)} fitxers no s'han trobat al disc. Primers 10:")
        for p in missing[:10]:
            print(f"  - {p}")
        print("Comprova que executes l'script des de AI-Night-Guardian-main")
        print("(la mateixa carpeta que conte dataset_final_16khz).")
    else:
        print("\nCap fitxer perdut. dataset_ready/ ja esta llest per pujar a Edge Impulse.")


if __name__ == "__main__":
    main()
