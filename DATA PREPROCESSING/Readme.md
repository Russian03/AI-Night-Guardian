# Data preprocessing

Scripts that turn the raw audio collection in `DATASET/final_dataset_16khz/`
into the training set uploaded to Edge Impulse™.

The reasoning behind each step is in the technical report
(`DOCUMENTATION/`). This file only covers how to run them.

## Requirements

```bash
pip install numpy soundfile
pip install tensorflow tensorflow-hub   # only for yamnet_clean.py
```

## Running the pipeline

From this folder, in order:

```bash
# 1. Inventory: consolidate labels, drop duplicates and corrupt files,
#    cap each class. Writes one CSV row per file.
python build_manifest.py ../DATASET/final_dataset_16khz manifest.csv

# 2. Copy the selected clips into one folder per class
python materialize_dataset.py manifest.csv dataset_ready

# 3. Segment into 2 s clips, keeping only fragments where YAMNet
#    confirms the labelled sound
python yamnet_clean.py dataset_ready dataset_ready_yamnet

# 4. Random gain per clip, so the model doesn't depend on absolute level
python augment_gain.py dataset_ready_yamnet dataset_ready_gain

# 5. Silence class, from a recording of the room (see below)
python prepare_room_audio.py recording.wav dataset_ready_gain/silenci
```

The result is `dataset_ready_gain/`, one folder per class of 2-second WAV
clips at 16 kHz mono, ready to upload to Edge Impulse™.

All sampling uses a fixed seed, so the output is reproducible.

## The scripts

| Script | What it does |
|---|---|
| `build_manifest.py` | Maps the 47 source labels to the 5 final classes, finds duplicates by MD5, flags corrupt and short files, applies per-class caps with sampling stratified by source label |
| `materialize_dataset.py` | Copies the clips marked `keep_for_training` into one folder per class |
| `segment_events.py` | Energy-based segmentation into 2 s clips. Superseded by `yamnet_clean.py` for the final dataset, but works without TensorFlow |
| `yamnet_clean.py` | Semantic segmentation: keeps only fragments where YAMNet confirms the expected sound, drops clips where it confirms nothing |
| `augment_gain.py` | Rescales each clip to a random level between −50 and −15 dBFS |
| `prepare_room_audio.py` | Cuts a long recording into 2 s clips and reports its RMS levels |

## `recordings/`

501 two-second clips of a quiet room, recorded with the deployment
microphone. This is the `silenci` class.

It exists because every other step of the pipeline keeps only fragments with
audible sound, so the model never saw silence — and at night silence is most
of what the microphone hears. Without a class for it, the classifier spread
the probability across the classes it knew and raised `impacte` alerts at
87–91 % confidence in an empty room.

These clips are **not** passed through `augment_gain.py`: silence is defined
by its level, so rescaling it would defeat the purpose.

### Recording your own

The class is specific to a room and a microphone. To adapt the system to a
new environment, record ~15 minutes of the target room with no incidents —
mostly quiet, with some background and a few minutes of television — and run:

```bash
python prepare_room_audio.py recording.wav silenci
```

Besides cutting the clips, it prints the RMS levels of the recording, which
is what sets the energy gate (`SILENCE_RMS`) on the device.
