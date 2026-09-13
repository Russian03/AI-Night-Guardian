"""
AI Night Guardian - prepara la gravacio de la vostra habitacio
=================================================================

QUIN PROBLEMA RESOL
-------------------
El model no ha vist SILENCI ni una sola vegada durant l'entrenament: tots
els passos del pipeline (segment_events, yamnet_clean) conserven nomes
fragments amb so audible. A la nit, pero, el silenci es el 90% del que
arriba al microfon. El model rep una entrada que no s'assembla a res del
seu entrenament i la softmax ha de repartir la probabilitat entre les 4
classes existents -- no pot dir "cap". Per aixo dispara "impacte" amb
confianca alta sobre una habitacio buida.

Aquest script agafa una gravacio llarga feta amb el VOSTRE microfon a la
VOSTRA habitacio i la talla en clips de 2s llestos per pujar a Edge
Impulse com a classe nova. Aixi el model apren com sona el "no passa res"
amb el vostre hardware concret.

QUE GRAVAR
----------
Uns 15 minuts en total, per exemple:
  - 10 min d'habitacio buida en silenci (el cas dominant a la nit)
  - 3 min amb la tele o la radio de fons
  - 2 min amb sorolls de fons normals (finestra oberta, passadis...)

NO hi ha d'haver cops, crits ni tos: nomes fons.

REQUEREIX
---------
    pip install numpy soundfile

US
--
    python prepare_room_audio.py gravacio.wav dataset_ready_yamnet/silenci

Despres pugeu la carpeta a Edge Impulse com a classe "silenci" i
reentreneu. A l'Arduino, "silenci" mapeja a cap alerta, igual que
"normal".
"""

import sys
from pathlib import Path

import numpy as np
import soundfile as sf

WINDOW_SEC = 2.0
HOP_SEC = 1.0          # 50% de solapament -> mes mostres de la mateixa gravacio
TARGET_SR = 16000      # ha de coincidir amb el dataset d'entrenament


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
        print(f"AVIS: la gravacio es a {sr} Hz i el dataset es a {TARGET_SR} Hz.")
        print("Torna a gravar a 16 kHz o converteix-la abans (per exemple amb")
        print(f"  ffmpeg -i {src.name} -ar 16000 -ac 1 gravacio_16k.wav")
        sys.exit(1)

    win = int(WINDOW_SEC * sr)
    hop = int(HOP_SEC * sr)
    if len(audio) < win:
        print("La gravacio es mes curta que la finestra de 2s.")
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

    print(f"Durada de la gravacio:  {len(audio)/sr/60:.1f} min")
    print(f"Clips generats:         {n}")
    print()
    print("Nivells (utils per calibrar el llindar del VAD):")
    print(f"  RMS minim:     {rms.min():.5f}   ({db.min():.1f} dBFS)")
    print(f"  RMS mediana:   {np.median(rms):.5f}   ({np.median(db):.1f} dBFS)")
    print(f"  RMS percentil 95: {np.percentile(rms, 95):.5f}   "
          f"({np.percentile(db, 95):.1f} dBFS)")
    print()
    print("Per al VAD, un punt de partida raonable es el percentil 95 d'aquesta")
    print("gravacio de fons: el que el superi es probablement un esdeveniment.")
    print("Ajusteu-lo amb proves reals (tossir, tancar la porta) per assegurar")
    print("que els esdeveniments el superen amb marge.")
    print()
    print(f"Clips a: {out_dir.resolve()}")


if __name__ == "__main__":
    main()
