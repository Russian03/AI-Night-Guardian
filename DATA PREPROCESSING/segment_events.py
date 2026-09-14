"""
AI Night Guardian - event-based segmentation (replaces crop_events)
=============================================================================

Why this is better than cropping a fixed 2s section:

  FSD50K/AudioSet clips use WEAK LABELING: the label indicates that
  the sound appears AT SOME POINT, not that it fills the entire clip. A
  10s clip labeled "cough" may contain 1s of coughing and 9s of silence.
  If we split it into 1s windows, most of them are silence labeled as
  cough, and the model learns that silence is cough.

  This script detects ALL regions in a clip where the energy exceeds the
  clip's own background noise, and exports each one as an independent
  sample. A clip with three cough events produces three clean samples
  instead of one bad one, silence is left out, and the event
  classes gain more samples.

  For the negative "normal" class, looking for peaks does NOT make sense
  (the sound is continuous and looking for peaks would create artificial
  transients that could be confused with impacts), so random windows are
  selected, discarding only those that are pure silence.

Requires numpy and soundfile:
    pip install numpy soundfile

Usage:
    python segment_events.py dataset_ready dataset_ready_segmented
"""

import random
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

WINDOW_SEC = 2.0        # duration of each exported sample
FRAME_SEC = 0.025       # energy analysis window
HOP_SEC = 0.010
THRESHOLD_DB = 10.0     # dB above the clip's background noise
MIN_EVENT_SEC = 0.08    # discard very short peaks (clicks, artifacts)
MERGE_GAP_SEC = 0.25    # merge events separated by less than this
MAX_SEGMENTS = 3        # limit per clip, so a long clip does not dominate
SEED = 42

# classes where the sound is continuous -> random windows instead of events
CONTINUOUS_CLASSES = {"normal"}


def frame_energies_db(audio, sr):
    frame = int(FRAME_SEC * sr)
    hop = int(HOP_SEC * sr)
    if len(audio) < frame:
        return np.array([]), hop
    n = 1 + (len(audio) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    frames = audio[idx]
    rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))
    return 20 * np.log10(rms + 1e-10), hop


def find_events(audio, sr):
    """Returns a list of (start, end) in samples for active regions."""
    db, hop = frame_energies_db(audio, sr)
    if db.size == 0:
        return []

    noise_floor = np.percentile(db, 20)
    active = db > (noise_floor + THRESHOLD_DB)
    if not active.any():
        return []

    # contiguous active regions
    edges = np.diff(active.astype(int))
    starts = list(np.where(edges == 1)[0] + 1)
    ends = list(np.where(edges == -1)[0] + 1)
    if active[0]:
        starts.insert(0, 0)
    if active[-1]:
        ends.append(len(active))

    regions = [(s * hop, e * hop) for s, e in zip(starts, ends)]

    # merge nearby regions
    merged = []
    for s, e in regions:
        if merged and s - merged[-1][1] < MERGE_GAP_SEC * sr:
            merged[-1] = (merged[-1][0], e)
        else:
            merged.append((s, e))

    # discard very short regions, sort by energy and keep the best ones
    min_len = MIN_EVENT_SEC * sr
    merged = [(s, e) for s, e in merged if e - s >= min_len]
    merged.sort(key=lambda r: float(np.sum(audio[r[0]:r[1]].astype(np.float64) ** 2)),
                reverse=True)
    return merged[:MAX_SEGMENTS]


def window_around(audio, center, win):
    """Returns a win-sample window centered on a point, with zero-padding if needed."""
    start = int(center - win // 2)
    seg = np.zeros(win, dtype=audio.dtype)
    src_start = max(0, start)
    src_end = min(len(audio), start + win)
    seg[src_start - start : src_end - start] = audio[src_start:src_end]
    return seg


def process(path_in, out_dir, continuous):
    audio, sr = sf.read(path_in)
    if audio.ndim > 1:
        audio = audio[:, 0]
    win = int(WINDOW_SEC * sr)

    if continuous:
        if len(audio) <= win:
            segments = [window_around(audio, len(audio) // 2, win)]
        else:
            k = min(MAX_SEGMENTS, max(1, (len(audio) - win) // win))
            starts = random.sample(range(len(audio) - win + 1), k)
            segments = [audio[s : s + win] for s in starts]
            # discard windows that are pure silence
            db_all, _ = frame_energies_db(audio, sr)
            floor = np.percentile(db_all, 20) if db_all.size else -100
            segments = [
                s for s in segments
                if 20 * np.log10(np.sqrt(np.mean(s.astype(np.float64) ** 2)) + 1e-10)
                > floor + 3
            ] or [audio[starts[0] : starts[0] + win]]
    else:
        events = find_events(audio, sr)
        if not events:
            return 0
        segments = [window_around(audio, (s + e) // 2, win) for s, e in events]

    for i, seg in enumerate(segments):
        suffix = "" if len(segments) == 1 else f"_s{i}"
        sf.write(out_dir / f"{path_in.stem}{suffix}.wav", seg, sr)
    return len(segments)


def main():
    random.seed(SEED)
    src_root = Path(sys.argv[1] if len(sys.argv) > 1 else "dataset_ready")
    dst_root = Path(sys.argv[2] if len(sys.argv) > 2 else "dataset_ready_segmented")

    errors, dropped = [], 0
    for class_dir in sorted(p for p in src_root.iterdir() if p.is_dir()):
        continuous = class_dir.name in CONTINUOUS_CLASSES
        out_dir = dst_root / class_dir.name
        out_dir.mkdir(parents=True, exist_ok=True)

        n_in = n_out = 0
        for wav_path in class_dir.glob("*.wav"):
            n_in += 1
            try:
                made = process(wav_path, out_dir, continuous)
                n_out += made
                if made == 0:
                    dropped += 1
            except Exception as e:
                errors.append((str(wav_path), str(e)))

        mode = "random" if continuous else "events"
        print(f"  {class_dir.name:14s} {mode:9s} {n_in:5d} clips -> {n_out:5d} samples"
              f"  (~{n_out * 3} windows)")

    print(f"\nClips with no detected event (discarded): {dropped}")
    if errors:
        print(f"Errors: {len(errors)}. First 3:")
        for p, e in errors[:3]:
            print(f"  - {p}: {e}")
    print(f"\nResult saved to: {dst_root.resolve()}")


if __name__ == "__main__":
    main()
