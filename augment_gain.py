"""
AI Night Guardian - augmentacio de guany del dataset
=======================================================

QUIN PROBLEMA RESOL
-------------------
El bloc MFE NO es invariant al nivell: normalitza contra un noise floor
fix, no contra l'energia del senyal. El mateix so a -16 dBFS i a -50 dBFS
produeix caracteristiques molt diferents (mesurat: desplacament mitja de
-0.33 en una escala de 0 a 1).

Mesures reals d'aquesta installacio:
    clip del dataset      RMS 4857   (-16.6 dBFS)
    palmada a prop        RMS  741
    palmada lluny         RMS  365
    caiguda del sofa      RMS  148
    parlant               RMS   50-70
    silenci               RMS   24

O sigui: el desplegament treballa ~30 dB per sota del dataset, i a mes el
MATEIX esdeveniment dona 148 o 741 segons la distancia. No hi ha cap
nivell unic al qual ajustar el dataset.

La solucio no es escalar el dataset a un nivell concret, sino fer el model
ROBUST al nivell: que vegi cada so a moltes intensitats. Aixi deixa de
dependre del volum absolut i s'ha de fixar en la forma espectral, que es
el que realment distingeix un cop d'una veu.

Aixo tambe fa el sistema robust a la DISTANCIA, que es la variable que
mes canvia entre una residencia i una altra.

REQUEREIX
---------
    pip install numpy soundfile

US
--
    python augment_gain.py dataset_ready_yamnet dataset_ready_gain

No multiplica la mida del dataset: assigna a cada clip un guany aleatori,
aixi que l'entrenament triga el mateix.
"""

import random
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

SEED = 42

# Rang de nivells objectiu, en dBFS de RMS. Cobreix des del nivell del
# dataset original (-17) fins al dels esdeveniments fluixos i llunyans
# mesurats al dispositiu (-47), amb marge als dos extrems.
TARGET_DBFS_MIN = -50.0
TARGET_DBFS_MAX = -15.0

# Proporcio de clips que es deixen al nivell original. Convé no reescalar
# absolutament tot: manté una referencia neta dins del conjunt.
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
    # evita saturacio: si el pic passaria d'1.0, redueix el guany
    peak = np.abs(out).max()
    if peak > 0.99:
        out = out * (0.99 / peak)

    # es guarda en PCM_16 a proposit: el microfon real tambe entrega 16
    # bits en aquest rang, aixi que la perdua de resolucio dels nivells
    # baixos forma part del que el model ha d'aprendre a gestionar.
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
                print(f"  error a {wav_path.name}: {e}")

        all_levels += levels
        if levels:
            print(f"  {class_dir.name:14s} {n:5d} clips   "
                  f"nivells {min(levels):.0f} a {max(levels):.0f} dBFS")

    if all_levels:
        arr = np.array(all_levels)
        print()
        print(f"Nivells del dataset resultant: {arr.min():.0f} a {arr.max():.0f} dBFS "
              f"(mediana {np.median(arr):.0f})")
        print("El dispositiu mesura entre -55 (parlant) i -33 dBFS (palmada a prop),")
        print("aixi que aquest rang cobreix el desplegament real amb marge.")
    print(f"\nResultat a: {dst_root.resolve()}")


if __name__ == "__main__":
    main()
