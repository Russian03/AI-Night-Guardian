"""
AI Night Guardian - dataset cleaning and re-labeling pipeline (v3)
==================================================================

Generates a manifest.csv with, for each WAV file:
  - original label and final label (consolidated into 4 classes)
  - actual duration
  - whether it is corrupted/empty (duration 0.0s)
  - whether it is an exact duplicate (using MD5 hash)
  - whether it needs padding (duration < 1s)
  - whether it should be kept for training (keep_for_training)

v3 change: context_normal and domestic_noise have been split into
acoustically more homogeneous classes (human_voice, outdoor_noise,
domestic_actions, device_alarms), because the original context_normal
class mixed sounds that were too different and was becoming a
"catch-all" class during training.

The script can be re-run whenever new audio files arrive: simply point
it to the root dataset folder again.

Usage:
    python build_manifest.py <dataset_folder> [output_manifest.csv]

Works both with a folder structure (dataset/<class>/*.wav) and with a
single flat folder where the label is encoded in the filename
(label_fsd50k_id.wav, label_idyoutube_start_end.wav...).

If you have a CSV with columns (filepath,label), use
build_manifest_from_csv() instead of build_manifest().
"""

import csv
import hashlib
import random
import sys
import wave
from collections import Counter, defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# 1. Label consolidation map -> 8 final classes
#    None     = discard from the training set
#    "REVIEW" = listen to samples before deciding
# ---------------------------------------------------------------------------
LABEL_MAP = {
    # ================= CRITICAL CLASSES =================
    # impact -> possible fall. Includes "door": a door slam and a falling
    # body produce the same low-frequency transient and cannot be separated
    # with these labels. At night, inside the room, both deserve a check.
    "bang": "impact",
    "thumpandthud": "impact",
    "thumpthud": "impact",
    "door": "impact",

    # distressed voice -> immediate alert. Screams and crying are merged:
    # they were being confused with each other and trigger the same alert.
    "screaming": "distressed_voice",
    "shout": "distressed_voice",
    "yell": "distressed_voice",
    "cryingandsobbing": "distressed_voice",
    "cryingsobbing": "distressed_voice",
    "cryingbaby": "distressed_voice",
    "babyinfantcry": "distressed_voice",

    # cough -> moderate attention
    "cough": "cough",
    "coughing": "cough",
    "tos": "cough",

    # ================= SINGLE NEGATIVE CLASS =================
    # Everything that does NOT trigger an alert goes here. Separating it
    # into subclasses (ambient/normal_voice/breathing) did not improve
    # anything and generated confusions between them that are operationally
    # irrelevant: they all go to the same place on the Arduino.
    # Snoring IS important here: it is the dominant sound throughout the
    # night and the model needs a correct place to classify it, otherwise
    # it would classify it as cough and trigger an alert every night.
    "speech": "normal",
    "humanvoice": "normal",
    "conversation": "normal",
    "chatter": "normal",
    "whispering": "normal",
    "snoring": "normal",
    "breathing": "normal",
    "wheeze": "normal",
    "rain": "normal",
    "thunderstorm": "normal",
    "water": "normal",
    "carpassingby": "normal",
    "trafficandroadwaynoise": "normal",
    "trafficnoiseroadwaynoise": "normal",
    "vehiclehorncarhornhonking": "normal",
    "emergencyvehicle": "normal",
    "alarm": "normal",
    "alarmclock": "normal",
    "clockalarm": "normal",
    "siren": "normal",
    "footsteps": "normal",
    "walkandfootsteps": "normal",
    "walkfootsteps": "normal",
    "toiletflush": "normal",

    # ================= DISCARDED =================
    # Laughter and crying share vocal mechanisms and burst structure:
    # known confusion with distressed_voice, and laughter is rare at night.
    "laughing": None,
    "laughter": None,
    "sneeze": None,
    "sneezing": None,
    "burpingandeructation": None,
    "burpingeructation": None,

    # silence: handled using an energy threshold (VAD) before inference,
    # not as a class.
    "silence": None,

    # respiratorysounds is the parent category of cough/snore/breathing
    # in AudioSet: it would contaminate the cough/normal boundary.
    "respiratorysounds": None,
    "insidesmallroom": None,
}

# Maximum number of samples per final class. Only applied if the class
# exceeds the limit, using stratified sampling by original label to
# preserve diversity (e.g. context_normal is not filled only with speech).
MAX_SAMPLES_PER_FINAL_CLASS = 800

# The "normal" class groups many different sounds, so it is given more
# samples to cover this variety. The resulting imbalance is compensated
# using "Auto-weight classes" in Edge Impulse.
#
# The critical classes use ALL available samples (their real totals are
# ~1989 and ~1289, below these limits). Limiting them to 800 as we did
# before would discard data precisely where we have fewer samples.
# The resulting imbalance is compensated using "Auto-weight classes"
# in Edge Impulse.
PER_CLASS_CAP = {
    "impact": 2000,
    "distressed_voice": 2000,
    "cough": 1500,
    "normal": 2500,
}

SEED = 42

# Known labels, sorted from longest to shortest so that prefix matching
# selects "alarmclock" before "alarm" when both could match.
_KNOWN_LABELS_SORTED = sorted(LABEL_MAP.keys(), key=len, reverse=True)


# ---------------------------------------------------------------------------
# 2. Low-level utilities
# ---------------------------------------------------------------------------
def infer_label_from_filename(path: Path) -> str:
    """Extracts the original label from the FILE NAME, not the folder.

    Works with FSD50K names (label_fsd50k_id.wav) and AudioSet names
    (label_youtube_id_start_end.wav) and any other convention, as long
    as the file starts with one of the known LABEL_MAP labels followed
    by "_". If there is no match, returns the full filename stem
    (which will appear as UNKNOWN later, as intended).
    """
    stem = path.stem

    for lbl in _KNOWN_LABELS_SORTED:
        if stem == lbl or stem.startswith(lbl + "_"):
            return lbl

    return stem


def wav_duration(path: Path) -> float:
    """Duration in seconds. Returns -1.0 if the file cannot be read."""
    try:
        with wave.open(str(path), "rb") as w:
            frames = w.getnframes()
            rate = w.getframerate()
            return frames / float(rate) if rate else 0.0
    except Exception:
        return -1.0


def md5sum(path: Path, block_size: int = 65536) -> str:
    h = hashlib.md5()

    with open(path, "rb") as f:
        for block in iter(lambda: f.read(block_size), b""):
            h.update(block)

    return h.hexdigest()


# ---------------------------------------------------------------------------
# 3. Manifest construction
# ---------------------------------------------------------------------------
def build_manifest(dataset_root: str, output_csv: str):
    """Works both with a flat folder where the label is encoded in the
    filename (label_fsd50k_id.wav, label_id_start_end.wav...)
    and with one folder per class. In the latter case, the filename
    usually matches the folder name, so the result is the same.
    """
    root = Path(dataset_root)

    wav_paths = sorted(root.rglob("*.wav"))
    entries = [(p, infer_label_from_filename(p)) for p in wav_paths]

    return _process_entries(entries, output_csv)


def build_manifest_from_csv(
    dataset_root: str,
    labels_csv: str,
    output_csv: str
):
    """Alternative if labels come from a CSV (columns: filepath,label)
    instead of a folder structure.
    """
    root = Path(dataset_root)
    entries = []

    with open(labels_csv, newline="") as f:
        for row in csv.DictReader(f):
            entries.append((root / row["filepath"], row["label"]))

    return _process_entries(entries, output_csv)


def _process_entries(entries, output_csv):
    rows = []
    seen_hashes = {}

    for wav_path, orig_label in entries:
        duration = wav_duration(wav_path)

        file_hash = md5sum(wav_path) if duration >= 0 else None

        is_duplicate = (
            file_hash is not None
            and file_hash in seen_hashes
        )

        if file_hash is not None and not is_duplicate:
            seen_hashes[file_hash] = str(wav_path)

        final_label = LABEL_MAP.get(orig_label, "UNKNOWN")

        rows.append(
            {
                "filepath": str(wav_path),
                "orig_label": orig_label,
                "final_label": final_label,
                "duration_sec": round(duration, 3),
                "md5": file_hash or "",
                "is_duplicate": is_duplicate,
                "is_corrupt_or_empty": duration <= 0.0,
                "needs_padding": 0.0 < duration < 1.0,
            }
        )

    rows = _subsample_majority_classes(rows)

    _write_csv(rows, output_csv)
    _print_summary(rows)

    return rows


# ---------------------------------------------------------------------------
# 4. Stratified sampling of majority classes
# ---------------------------------------------------------------------------
def _subsample_majority_classes(
    rows,
    cap=MAX_SAMPLES_PER_FINAL_CLASS,
    seed=SEED
):
    random.seed(seed)

    eligible = [
        r
        for r in rows
        if not r["is_duplicate"]
        and not r["is_corrupt_or_empty"]
        and r["final_label"] not in ("UNKNOWN", None, "REVIEW")
    ]

    by_final = defaultdict(list)

    for r in eligible:
        by_final[r["final_label"]].append(r)

    keep_paths = set()

    for final_label, group in by_final.items():
        cap = PER_CLASS_CAP.get(
            final_label,
            MAX_SAMPLES_PER_FINAL_CLASS
        )

        total = len(group)

        if total <= cap:
            keep_paths.update(r["filepath"] for r in group)
            continue

        # Stratified sampling by original label -> preserves diversity.
        by_orig = defaultdict(list)

        for r in group:
            by_orig[r["orig_label"]].append(r)

        selected_paths = set()

        for orig_label, sub in by_orig.items():
            n = max(1, round(cap * len(sub) / total))
            n = min(n, len(sub))

            for r in random.sample(sub, n):
                selected_paths.add(r["filepath"])

        if len(selected_paths) > cap:
            selected_paths = set(
                random.sample(sorted(selected_paths), cap)
            )

        elif len(selected_paths) < cap:
            remaining = [
                r
                for r in group
                if r["filepath"] not in selected_paths
            ]

            extra_needed = min(
                cap - len(selected_paths),
                len(remaining)
            )

            if extra_needed > 0:
                for r in random.sample(remaining, extra_needed):
                    selected_paths.add(r["filepath"])

        keep_paths.update(selected_paths)

    for r in rows:
        r["keep_for_training"] = r["filepath"] in keep_paths

    return rows


# ---------------------------------------------------------------------------
# 5. Output
# ---------------------------------------------------------------------------
def _write_csv(rows, output_csv):
    if not rows:
        print("No files found.")
        return

    fieldnames = list(rows[0].keys())

    with open(output_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _print_summary(rows):
    kept = [r for r in rows if r["keep_for_training"]]

    dup = sum(1 for r in rows if r["is_duplicate"])
    corrupt = sum(
        1 for r in rows
        if r["is_corrupt_or_empty"]
    )
    review = sum(
        1 for r in rows
        if r["final_label"] == "REVIEW"
    )
    unknown = sum(
        1 for r in rows
        if r["final_label"] == "UNKNOWN"
    )
    padding = sum(
        1 for r in rows
        if r["needs_padding"]
    )

    print(f"Total scanned:           {len(rows)}")
    print(f"Duplicates detected:     {dup}")
    print(f"Corrupted/empty (0.0s):  {corrupt}")
    print(f"Pending review:          {review} "
          f"(respiratorysounds, insidesmallroom)")
    print(f"Unknown label:           {unknown}")
    print(f"Need padding <1s:        {padding}")
    print(f"Kept for training:       {len(kept)}")
    print()

    print("Final distribution "
          "(only kept samples, after applying the cap):")

    for label, n in Counter(
        r["final_label"] for r in kept
    ).most_common():
        print(f"  {label:20s} {n}")


    if unknown:
        unknown_labels = sorted(
            {
                r["orig_label"]
                for r in rows
                if r["final_label"] == "UNKNOWN"
            }
        )

        print()
        print(
            f"WARNING: {unknown} files have a label "
            f"that does not appear in LABEL_MAP:"
        )

        for lbl in unknown_labels:
            n = sum(
                1
                for r in rows
                if r["orig_label"] == lbl
            )

            print(f"  - {lbl}  ({n} files)")

        print(
            "Decide which final class they should map to "
            "(or None to discard them)"
        )

        print(
            "and add them to LABEL_MAP before considering "
            "the manifest valid."
        )

        print(
            "These files remain excluded from "
            "'keep_for_training' until you do so."
        )


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    dataset_root = (
        sys.argv[1]
        if len(sys.argv) > 1
        else "./dataset"
    )

    output_csv = (
        sys.argv[2]
        if len(sys.argv) > 2
        else "manifest.csv"
    )

    build_manifest(dataset_root, output_csv)
