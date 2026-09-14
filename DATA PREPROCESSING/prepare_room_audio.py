"""
AI Night Guardian - prepares your room recording
=================================================================

WHAT PROBLEM DOES IT SOLVE
--------------------------
The model has not seen SILENCE even once during training: all
pipeline steps (segment_events, yamnet_clean) keep only
fragments with audible sound. At night, however, silence is 90% of what
reaches the microphone. The model receives an input that does not
resemble anything from its training data, and the softmax has to
distribute the probability among the 4 existing classes -- it cannot say
"none". This is why it may trigger "impacte" with high confidence in an
empty room.

This script takes a long recording made with YOUR microphone in YOUR
room and splits it into 2s clips ready to upload to Edge
Impulse as a new class. This way, the model learns what "nothing is
happening" sounds like with your specific hardware.

WHAT TO RECORD
--------------
Around 15 minutes in total, for example:
  - 10 min of an empty room in silence (the dominant situation at night)
  - 3 min with a TV or radio in the background
  - 2 min with normal background noises (open window, hallway...)

There should NOT be any impacts, screams, or coughs: only background
noise.

REQUIRES
--------
    pip install numpy soundfile

USAGE
-----
    python prepare_room_audio.py gravacio.wav dataset_ready_yamnet/silenci

Then upload the folder to Edge Impulse as a "silenci" class and
retrain. On the Arduino, "silenci" maps to no alert, just like
"normal".
"""

import sys
from pathlib import Path

import numpy as np
import soundfile as sf

WINDOW_SEC = 2.0
HOP_SEC = 1.0          # 50% overlap -> more samples from the same recording
TARGET_SR = 16000      # must match the training dataset


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    src = Path(sys.argv[1])
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else "silenci")
    out_dir.mkdir(parents=True, exist_ok=True)

    audio, sr = sf.read(src, dtype="float32")
    if audio.ndim > 1:
        audio = audio[:, 0]

    if sr != TARGET_SR:
        print(f"WARNING: the recording is at {sr} Hz and the dataset is at {TARGET_SR} Hz.")
        print("Record at 16 kHz or convert it beforehand (for example with")
        print(f"  ffmpeg -i {src.name} -ar 16000 -ac 1 gravacio_16k.wav")
        sys.exit(1)

    win = int(WINDOW_SEC * sr)
    hop = int(HOP_SEC * sr)
    if len(audio) < win:
        print("The recording is shorter than the 2s window.")
        sys.exit(1)

    rms_values = []
    n = 0
    for start in range(0, len(audio) - win + 1, hop):
        seg = audio[start : start + win]
        rms_values.append(float(np.sqrt(np.mean(seg.astype(np.float64) ** 2))))
        sf.write(out_dir / f"{src.stem}_{n:05d}.wav", seg, sr)
        n += 1

    rms = np.array(rms_values)
    db = 20 * np.log10(rms + 1e-10)

    print(f"Recording duration:     {len(audio)/sr/60:.1f} min")
    print(f"Clips generated:         {n}")
    print()
    print("Levels (useful for calibrating the VAD threshold):")
    print(f"  Minimum RMS:     {rms.min():.5f}   ({db.min():.1f} dBFS)")
    print(f"  Median RMS:      {np.median(rms):.5f}   ({np.median(db):.1f} dBFS)")
    print(f"  95th percentile RMS: {np.percentile(rms, 95):.5f}   "
          f"({np.percentile(db, 95):.1f} dBFS)")
    print()
    print("For the VAD, a reasonable starting point is the 95th percentile of this")
    print("background recording: anything above it is probably an event.")
    print("Adjust it using real tests (coughing, closing the door) to make sure")
    print("events exceed the threshold with enough margin.")
    print()
    print(f"Clips saved to: {out_dir.resolve()}")


if __name__ == "__main__":
    main()
