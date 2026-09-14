"""
AI Night Guardian - materialize the final dataset
====================================================

Reads manifest_corregit.csv and copies ONLY the files marked
keep_for_training=True into a class-based folder structure,
ready to drag/upload to Edge Impulse Studio.

Execution (from the AI-Night-Guardian-main folder, where
dataset_final_16khz/ and manifest_corregit.csv are located):

    python materialize_dataset.py

Generates:
    dataset_ready/
        tos/*.wav
        crit_ajuda/*.wav
        caiguda_cop/*.wav
        plor_angoixa/*.wav
        roncs/*.wav
        silenci_ambient/*.wav
        context_normal/*.wav
        soroll_domestic/*.wav

It can be re-run safely: if dataset_ready already exists, it only
adds/overwrites files; it does not delete anything by itself.
"""

import csv
import shutil
import sys
from pathlib import Path
from collections import Counter

MANIFEST_PATH = sys.argv[1] if len(sys.argv) > 1 else "manifest_corregit.csv"
OUTPUT_DIR = Path(sys.argv[2] if len(sys.argv) > 2 else "dataset_ready")
DATASET_ROOT = Path(".")  # manifest paths are relative to this location


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

    print(f"Files copied: {sum(copied.values())}")
    for label, n in copied.most_common():
        print(f"  {label}: {n}")
    print(f"\nFiltered (keep_for_training=False, already excluded): {skipped_not_kept}")

    if missing:
        print(f"\nWARNING: {len(missing)} files were not found on disk. First 10:")
        for p in missing[:10]:
            print(f"  - {p}")
        print("Check that you are running the script from AI-Night-Guardian-main")
        print("(the same folder containing dataset_final_16khz).")
    else:
        print("\nNo missing files. dataset_ready/ is ready to upload to Edge Impulse.")


if __name__ == "__main__":
    main()
