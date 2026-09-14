"""
AI Night Guardian - dataset gain augmentation
================================================

WHAT PROBLEM IT SOLVES
----------------------
The MFE block is NOT invariant to signal level: it normalizes against a
fixed noise floor, not against the signal energy. The same sound at
-16 dBFS and -50 dBFS produces very different features (measured:
mean shift of -0.33 on a scale from 0 to 1).

Real measurements from this installation:
    dataset clip          RMS 4857   (-16.6 dBFS)
    close clap            RMS  741
    distant clap          RMS  365
    sofa fall             RMS  148
    speaker               RMS   50-70
    silence               RMS   24

In other words: the deployment operates ~30 dB below the dataset, and
the SAME event produces 148 or 741 depending on the distance. There is
no single level to which the dataset should be adjusted.

The solution is NOT to scale the dataset to a specific level, but to make
the model ROBUST to signal level: it should see each sound at many
different intensities. This way, it becomes less dependent on absolute
volume and has to focus on the spectral shape, which is what actually
distinguishes a thump from speech.

This also makes the system robust to DISTANCE, which is the variable that
changes the most between different care homes.

REQUIRES
--------
    pip install numpy soundfile

USAGE
-----
    python augment_gain.py dataset_ready_yamnet dataset_ready_gain

This does not increase the dataset size: each clip is assigned a random
gain, so training takes the same amount of time.
"""

import random
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

SEED = 42

# Target level range, in dBFS RMS. Covers the level of the original
# dataset (-17) down to the level of quiet and distant events
# measured on the device (-47), with some margin at both ends.
TARGET_DBFS_MIN = -50.0
TARGET_DBFS_MAX = -15.0

# Proportion of clips kept at their original level. It is useful not to
# rescale everything: this maintains a clean reference within the dataset.
KEEP_ORIGINAL_RATIO = 0.15


def rms_dbfs(x):
    r = float(np.sqrt(np.mean(x.astype(np.float64) ** 2)))
    return 20 * np.log10(max(r, 1e-12))


def process(path_in, path_out):
    audio, sr = sf.read(path_in, dtype="float32")
    if audio.ndim > 1:
        audio = audio[:, 0]

    if random.random() < KEEP_ORIGINAL_RATIO or np.all(audio == 0):
        sf.write(path_out, audio, sr, subtype="PCM_16")
        return None

    current = rms_dbfs(audio)
    target = random.uniform(TARGET_DBFS_MIN, TARGET_DBFS_MAX)
    gain = 10 ** ((target - current) / 20)

    out = audio * gain
    # Prevents clipping: if the peak would exceed 1.0, reduce the gain.
    peak = np.abs(out).max()
    if peak > 0.99:
        out = out * (0.99 / peak)

    # Saved as PCM_16 on purpose: the real microphone also outputs 16-bit
    # audio in this range, so the loss of resolution at low levels is part
    # of what the model must learn to handle.
    sf.write(path_out, out, sr, subtype="PCM_16")
    return rms_dbfs(out)


def main():
    random.seed(SEED)
    src_root = Path(sys.argv[1] if len(sys.argv) > 1 else "dataset_ready_yamnet")
    dst_root = Path(sys.argv[2] if len(sys.argv) > 2 else "dataset_ready_gain")

    all_levels = []
    for class_dir in sorted(p for p in src_root.iterdir() if p.is_dir()):
        out_dir = dst_root / class_dir.name
        out_dir.mkdir(parents=True, exist_ok=True)

        levels, n = [], 0
        for wav_path in class_dir.glob("*.wav"):
            try:
                lvl = process(wav_path, out_dir / wav_path.name)
                n += 1
                if lvl is not None:
                    levels.append(lvl)
            except Exception as e:
                print(f"  error in {wav_path.name}: {e}")

        all_levels += levels
        if levels:
            print(f"  {class_dir.name:14s} {n:5d} clips   "
                  f"levels {min(levels):.0f} to {max(levels):.0f} dBFS")

    if all_levels:
        arr = np.array(all_levels)
        print()
        print(f"Resulting dataset levels: {arr.min():.0f} to {arr.max():.0f} dBFS "
              f"(median {np.median(arr):.0f})")
        print("The device measures between -55 (speaker) and -33 dBFS (close clap),")
        print("so this range covers the real deployment with some margin.")
    print(f"\nOutput: {dst_root.resolve()}")


if __name__ == "__main__":
    main()
