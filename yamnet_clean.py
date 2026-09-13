"""
AI Night Guardian - neteja semantica del dataset amb YAMNet
==============================================================

QUIN PROBLEMA RESOL
-------------------
Els clips de FSD50K/AudioSet porten etiquetatge FEBLE: l'etiqueta diu que
el so hi apareix en algun moment, no que ompli el clip. La segmentacio per
energia (segment_events.py) agafa el tros MES SOROLLOS, que no
necessariament es el so etiquetat -- si un clip "cough" te algu parlant
fort i tossint fluix, agafem la parla i li posem l'etiqueta "tos".

YAMNet es un model entrenat sobre AudioSet (les mateixes dades d'on ve el
vostre dataset) que classifica 521 tipus de so cada 0.48 segons. Aixo
permet trobar els fragments on YAMNet CONFIRMA que hi ha el so esperat,
convertint etiquetes febles a nivell de clip en etiquetes fortes a nivell
de fragment.

INSTAL·LACIO
------------
    pip install tensorflow tensorflow-hub numpy soundfile

(La primera execucio descarrega el model de TF Hub, uns 20 MB.)

US
--
    python yamnet_clean.py dataset_ready dataset_ready_yamnet

Si YAMNet no confirma cap fragment d'un clip, el clip es descarta: es
justament el cas on l'etiqueta probablement era erronia.
"""

import sys
from pathlib import Path

import numpy as np
import soundfile as sf

WINDOW_SEC = 2.0
MAX_SEGMENTS = 3
# La classe negativa te molts mes clips de partida i YAMNet li'n descarta
# pocs, aixi que amb 3 fragments per clip generava ~3.75x mes mostres que
# veu_angoixa. Amb 1 fragment el dataset queda equilibrat.
SEGMENTS_PER_CLASS = {"normal": 1}
MIN_SCORE = 0.10  # confianca minima de YAMNet per acceptar un fragment
SR = 16000

# Les nostres classes -> noms de classe de YAMNet (ontologia AudioSet).
# Els noms han de coincidir amb els del class map de YAMNet; els que no
# existeixin s'ignoren amb un avis, aixi que es segur afegir-ne de dubtosos.
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

    print("Carregant YAMNet des de TF Hub (la primera vegada triga)...")
    model = hub.load("https://tfhub.dev/google/yamnet/1")
    class_map_path = model.class_map_path().numpy().decode("utf-8")
    names = []
    with tf.io.gfile.GFile(class_map_path) as f:
        next(f)  # capcalera
        for line in f:
            names.append(line.strip().split(",", 2)[2].strip('"'))
    print(f"YAMNet llest ({len(names)} classes).")
    return model, names


def build_index_map(class_names):
    """classe nostra -> llista d'indexs de YAMNet."""
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
            f"Avis: {len(missing)} noms no trobats al class map i ignorats: "
            f"{missing[:8]}{'...' if len(missing) > 8 else ''}"
        )
    return out


def window_around(audio, center, win):
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
    hop_sec = 0.48  # pas temporal de YAMNet
    chosen, made = [], 0
    for fi in order:
        if frame_score[fi] < MIN_SCORE or made >= max_segments:
            break
        center = int((fi * hop_sec + hop_sec / 2) * SR)
        if any(abs(center - c) < win // 2 for c in chosen):
            continue  # evita fragments gairebe iguals
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
            print(f"  {class_dir.name}: sense mapatge a YAMNet, saltada")
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
            f"  {class_dir.name:14s} {n_in:5d} clips -> {n_out:5d} mostres"
            f"   descartats: {dropped} ({pct:.0f}%)"
        )

    print(f"\nTotal clips descartats (YAMNet no hi confirma el so): {total_dropped}")
    print("Un percentatge alt de descartats en una classe indica que les seves")
    print("etiquetes eren poc fiables -- es informacio util per si sola.")
    print(f"\nResultat a: {dst_root.resolve()}")


if __name__ == "__main__":
    main()
