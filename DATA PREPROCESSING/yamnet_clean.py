"""
AI Night Guardian - semantic dataset cleaning with YAMNet
==============================================================

WHAT PROBLEM DOES IT SOLVE
--------------------------
FSD50K/AudioSet clips use WEAK LABELING: the label says that
the sound appears at some point, not that it fills the clip. Energy-based
segmentation (segment_events.py) takes the LOUDEST part, which does
not necessarily correspond to the labeled sound -- if a "cough" clip has
someone speaking loudly and coughing quietly, we take the speech and give
it the "tos" label.

YAMNet is a model trained on AudioSet (the same data source as your
dataset) that classifies 521 types of sound every 0.48 seconds. This
allows us to find the fragments where YAMNet CONFIRMS that the expected
sound is present, converting weak clip-level labels into strong
fragment-level labels.

INSTALLATION
------------
    pip install tensorflow tensorflow-hub numpy soundfile

(The first execution downloads the TF Hub model, around 20 MB.)

USAGE
-----
    python yamnet_clean.py dataset_ready dataset_ready_yamnet

If YAMNet does not confirm any fragment of a clip, the clip is discarded:
this is precisely the case where the label was probably incorrect.
"""

import sys
from pathlib import Path

import numpy as np
import soundfile as sf

WINDOW_SEC = 2.0
MAX_SEGMENTS = 3
# The negative class has many more starting clips and YAMNet discards
# only a few of them, so using 3 fragments per clip generated ~3.75x more
# samples than veu_angoixa. With 1 fragment, the dataset is more balanced.
SEGMENTS_PER_CLASS = {"normal": 1}
MIN_SCORE = 0.10  # minimum YAMNet confidence required to accept a fragment
SR = 16000

# Our classes -> YAMNet class names (AudioSet ontology).
# The names must match those in the YAMNet class map; names that do not
# exist are ignored with a warning, so it is safe to add uncertain ones.
CLASS_TO_YAMNET = {
    "impacte": [
        "Thump, thud",
        "Bang",
        "Slam",
        "Knock",
        "Thunk",
        "Smash, crash",
        "Door",
        "Sliding door",
        "Cupboard open or close",
        "Crash cymbal",
        "Wood",
    ],
    "veu_angoixa": [
        "Screaming",
        "Yell",
        "Shout",
        "Bellow",
        "Children shouting",
        "Whoop",
        "Crying, sobbing",
        "Baby cry, infant cry",
        "Whimper",
        "Wail, moan",
        "Groan",
    ],
    "tos": [
        "Cough",
        "Throat clearing",
    ],
    "normal": [
        "Speech",
        "Conversation",
        "Narration, monologue",
        "Male speech, man speaking",
        "Female speech, woman speaking",
        "Child speech, kid speaking",
        "Whispering",
        "Babbling",
        "Snoring",
        "Breathing",
        "Wheeze",
        "Gasp",
        "Sigh",
        "Rain",
        "Raindrop",
        "Rain on surface",
        "Thunderstorm",
        "Thunder",
        "Water",
        "Stream",
        "Gurgling",
        "Toilet flush",
        "Vehicle",
        "Car",
        "Car passing by",
        "Traffic noise, roadway noise",
        "Vehicle horn, car horn, honking",
        "Emergency vehicle",
        "Siren",
        "Civil defense siren",
        "Ambulance (siren)",
        "Alarm",
        "Alarm clock",
        "Beep, bleep",
        "Buzzer",
        "Smoke detector, smoke alarm",
        "Walk, footsteps",
        "Run",
        "Shuffle",
    ],
}


def load_yamnet():
    import tensorflow as tf
    import tensorflow_hub as hub

    print("Loading YAMNet from TF Hub (the first time may take a while)...")
    model = hub.load("https://tfhub.dev/google/yamnet/1")
    class_map_path = model.class_map_path().numpy().decode("utf-8")
    names = []
    with tf.io.gfile.GFile(class_map_path) as f:
        next(f)  # header
        for line in f:
            names.append(line.strip().split(",", 2)[2].strip('"'))
    print(f"YAMNet ready ({len(names)} classes).")
    return model, names


def build_index_map(class_names):
    """Our class -> list of YAMNet indices."""
    lookup = {n: i for i, n in enumerate(class_names)}
    out, missing = {}, []
    for our, targets in CLASS_TO_YAMNET.items():
        idxs = []
        for t in targets:
            if t in lookup:
                idxs.append(lookup[t])
            else:
                missing.append(t)
        out[our] = idxs
    if missing:
        print(
            f"Warning: {len(missing)} names not found in the class map and ignored: "
            f"{missing[:8]}{'...' if len(missing) > 8 else ''}"
        )
    return out


def window_around(audio, center, win):
    """Returns a win-sample window centered on a point, with zero-padding if needed."""
    start = int(center - win // 2)
    seg = np.zeros(win, dtype=np.float32)
    s0, s1 = max(0, start), min(len(audio), start + win)
    seg[s0 - start : s1 - start] = audio[s0:s1]
    return seg


def process(model, idxs, path_in, out_dir, max_segments=MAX_SEGMENTS):
    audio, sr = sf.read(path_in, dtype="float32")
    if audio.ndim > 1:
        audio = audio[:, 0]
    if sr != SR or len(audio) < SR // 2:
        return 0

    scores, _, _ = model(audio)
    scores = scores.numpy()  # (frames, 521)
    if scores.shape[0] == 0 or not idxs:
        return 0

    frame_score = scores[:, idxs].max(axis=1)
    order = np.argsort(frame_score)[::-1]

    win = int(WINDOW_SEC * SR)
    hop_sec = 0.48  # YAMNet temporal step
    chosen, made = [], 0
    for fi in order:
        if frame_score[fi] < MIN_SCORE or made >= max_segments:
            break
        center = int((fi * hop_sec + hop_sec / 2) * SR)
        if any(abs(center - c) < win // 2 for c in chosen):
            continue  # avoids nearly identical fragments
        chosen.append(center)
        suffix = "" if max_segments == 1 else f"_y{made}"
        sf.write(
            out_dir / f"{path_in.stem}{suffix}.wav",
            window_around(audio, center, win),
            SR,
        )
        made += 1
    return made


def main():
    src_root = Path(sys.argv[1] if len(sys.argv) > 1 else "dataset_ready")
    dst_root = Path(sys.argv[2] if len(sys.argv) > 2 else "dataset_ready_yamnet")

    model, class_names = load_yamnet()
    index_map = build_index_map(class_names)

    total_dropped = 0
    for class_dir in sorted(p for p in src_root.iterdir() if p.is_dir()):
        idxs = index_map.get(class_dir.name)
        if idxs is None:
            print(f"  {class_dir.name}: no YAMNet mapping, skipped")
            continue
        out_dir = dst_root / class_dir.name
        out_dir.mkdir(parents=True, exist_ok=True)
        max_seg = SEGMENTS_PER_CLASS.get(class_dir.name, MAX_SEGMENTS)

        n_in = n_out = dropped = 0
        for wav_path in class_dir.glob("*.wav"):
            n_in += 1
            try:
                made = process(model, idxs, wav_path, out_dir, max_seg)
                n_out += made
                if made == 0:
                    dropped += 1
            except Exception:
                dropped += 1
        total_dropped += dropped
        pct = 100 * dropped / n_in if n_in else 0
        print(
            f"  {class_dir.name:14s} {n_in:5d} clips -> {n_out:5d} samples"
            f"   discarded: {dropped} ({pct:.0f}%)"
        )

    print(f"\nTotal clips discarded (YAMNet did not confirm the sound): {total_dropped}")
    print("A high percentage of discarded clips in a class indicates that its")
    print("labels were unreliable -- this is useful information by itself.")
    print(f"\nResult saved to: {dst_root.resolve()}")


if __name__ == "__main__":
    main()
