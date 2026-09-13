"""
AI Night Guardian - pipeline de neteja i re-etiquetatge del dataset (v3)
==========================================================================

Genera un manifest.csv amb, per cada fitxer WAV:
  - etiqueta original i etiqueta final (consolidada, 4 classes)
  - durada real
  - si es corrupte/buit (duracio 0.0s)
  - si es duplicat exacte (per hash MD5)
  - si necessita padding (duracio < 1s)
  - si s'ha de mantenir per entrenar (keep_for_training)

Canvi v3: context_normal i soroll_domestic s'han desglossat en 4 classes
acusticament mes homogenies (veu_humana, soroll_exterior,
accions_domestiques, alarmes_dispositiu), perque la classe original
context_normal barrejava sons massa diferents entre si i s'estava
convertint en un calaix de sastre durant l'entrenament.

Es pot re-executar sempre que arribin nous audios: nomes cal tornar
a apuntar-lo a la carpeta arrel del dataset.

Us:
    python build_manifest.py <carpeta_dataset> [manifest_sortida.csv]

Funciona tant amb estructura de carpetes (dataset/<classe>/*.wav) com
amb una sola carpeta plana on l'etiqueta va codificada al nom de
fitxer (etiqueta_fsd50k_id.wav, etiqueta_idyoutube_inici_fi.wav...).
Si en comptes d'aixo teniu un CSV amb columnes (filepath,label),
feu servir build_manifest_from_csv() en lloc de build_manifest().
"""

import csv
import hashlib
import random
import sys
import wave
from collections import Counter, defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# 1. Mapa de consolidacio d'etiquetes -> 8 classes finals
#    None     = descartar del training set
#    "REVIEW" = cal escoltar mostres abans de decidir
# ---------------------------------------------------------------------------
LABEL_MAP = {
    # ================= CLASSES CRITIQUES =================
    # impacte -> possible caiguda. Inclou "door": un cop de porta i un cos
    # que cau produeixen el mateix transitori de baixa frequencia i no son
    # separables amb aquestes etiquetes. De nit, dins l'habitacio, tots dos
    # mereixen comprovacio.
    "bang": "impacte",
    "thumpandthud": "impacte",
    "thumpthud": "impacte",
    "door": "impacte",
    # veu_angoixa -> alerta immediata. Crits i plors fusionats: es confonien
    # entre ells i disparen la mateixa alerta.
    "screaming": "veu_angoixa",
    "shout": "veu_angoixa",
    "yell": "veu_angoixa",
    "cryingandsobbing": "veu_angoixa",
    "cryingsobbing": "veu_angoixa",
    "cryingbaby": "veu_angoixa",
    "babyinfantcry": "veu_angoixa",
    # tos -> atencio moderada
    "cough": "tos",
    "coughing": "tos",
    "tos": "tos",

    # ================= CLASSE NEGATIVA UNICA =================
    # Tot el que NO dispara alerta va aqui. Separar-ho en subclasses
    # (ambient/veu_normal/respiracio) no va millorar res i generava
    # confusions entre elles que operativament son irrellevants: totes
    # van al mateix lloc a l'Arduino. Els roncs SON importants aqui: son
    # el so dominant tota la nit i el model necessita un lloc correcte on
    # posar-los, o els classificaria com a tos i alertaria cada nit.
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

    # ================= DESCARTATS =================
    # riure i plor comparteixen mecanisme vocal i estructura de rafegues:
    # confusio coneguda amb veu_angoixa, i de nit el riure es rar.
    "laughing": None,
    "laughter": None,
    "sneeze": None,
    "sneezing": None,
    "burpingandeructation": None,
    "burpingeructation": None,
    # silence: es gestiona amb llindar d'energia (VAD) abans de la
    # inferencia, no com a classe.
    "silence": None,
    # respiratorysounds es la categoria PARE de cough/snore/breathing a
    # AudioSet: contaminaria la frontera tos/normal.
    "respiratorysounds": None,
    "insidesmallroom": None,
}

# Cap maxim per classe final. Nomes s'aplica si la classe el supera,
# i el mostreig es fa de forma estratificada per etiqueta original
# per preservar diversitat (ex: context_normal no s'omple nomes de "speech").
MAX_SAMPLES_PER_FINAL_CLASS = 800
# La classe "normal" agrupa molts sons diferents; li donem mes mostres per
# cobrir aquesta varietat. El desequilibri resultant es compensa amb
# "Auto-weight classes" a Edge Impulse.
# Les classes critiques usen TOTES les mostres disponibles (els seus totals
# reals son ~1989 i ~1289, per sota d'aquests caps). Capar-les a 800 com
# feiem abans llencava dades justament d'on menys en teniem. El
# desequilibri resultant el compensa "Auto-weight classes" a Edge Impulse.
PER_CLASS_CAP = {
    "impacte": 2000,
    "veu_angoixa": 2000,
    "tos": 1500,
    "normal": 2500,
}
SEED = 42

# Etiquetes conegudes, ordenades de mes llarga a mes curta perque el
# matching per prefix trii "alarmclock" abans que "alarm" quan tots dos
# encaixarien.
_KNOWN_LABELS_SORTED = sorted(LABEL_MAP.keys(), key=len, reverse=True)


# ---------------------------------------------------------------------------
# 2. Utilitats de baix nivell
# ---------------------------------------------------------------------------
def infer_label_from_filename(path: Path) -> str:
    """Extreu l'etiqueta original del NOM DE FITXER, no de la carpeta.

    Funciona amb noms de FSD50K (etiqueta_fsd50k_id.wav) i AudioSet
    (etiqueta_idyoutube_inici_final.wav) i qualsevol altra convencio,
    sempre que el fitxer comenci per una de les LABEL_MAP conegudes
    seguida de "_". Si no hi ha coincidencia, retorna el nom sencer
    (sortira com a UNKNOWN mes endavant, cosa volguda).
    """
    stem = path.stem
    for lbl in _KNOWN_LABELS_SORTED:
        if stem == lbl or stem.startswith(lbl + "_"):
            return lbl
    return stem


def wav_duration(path: Path) -> float:
    """Durada en segons. Retorna -1.0 si el fitxer no es pot llegir."""
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
# 3. Construccio del manifest
# ---------------------------------------------------------------------------
def build_manifest(dataset_root: str, output_csv: str):
    """Funciona tant si el dataset es una carpeta plana amb l'etiqueta
    codificada al nom de fitxer (etiqueta_fsd50k_id.wav, etiqueta_id_ini_fi.wav...)
    com si hi ha una carpeta per classe -- en aquest segon cas el nom de
    fitxer sol coincidir amb el de la carpeta, aixi que el resultat es el mateix."""
    root = Path(dataset_root)
    wav_paths = sorted(root.rglob("*.wav"))
    entries = [(p, infer_label_from_filename(p)) for p in wav_paths]
    return _process_entries(entries, output_csv)


def build_manifest_from_csv(dataset_root: str, labels_csv: str, output_csv: str):
    """Alternativa si les etiquetes venen en un CSV (columnes: filepath,label)
    en comptes d'estructura de carpetes."""
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
        is_duplicate = file_hash is not None and file_hash in seen_hashes
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
# 4. Mostreig estratificat de les classes majoritaries
# ---------------------------------------------------------------------------
def _subsample_majority_classes(rows, cap=MAX_SAMPLES_PER_FINAL_CLASS, seed=SEED):
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
        cap = PER_CLASS_CAP.get(final_label, MAX_SAMPLES_PER_FINAL_CLASS)
        total = len(group)
        if total <= cap:
            keep_paths.update(r["filepath"] for r in group)
            continue

        # mostreig estratificat per etiqueta original -> preserva diversitat
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
            selected_paths = set(random.sample(sorted(selected_paths), cap))
        elif len(selected_paths) < cap:
            remaining = [r for r in group if r["filepath"] not in selected_paths]
            extra_needed = min(cap - len(selected_paths), len(remaining))
            if extra_needed > 0:
                for r in random.sample(remaining, extra_needed):
                    selected_paths.add(r["filepath"])

        keep_paths.update(selected_paths)

    for r in rows:
        r["keep_for_training"] = r["filepath"] in keep_paths
    return rows


# ---------------------------------------------------------------------------
# 5. Sortida
# ---------------------------------------------------------------------------
def _write_csv(rows, output_csv):
    if not rows:
        print("Cap fitxer trobat.")
        return
    fieldnames = list(rows[0].keys())
    with open(output_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def _print_summary(rows):
    kept = [r for r in rows if r["keep_for_training"]]
    dup = sum(1 for r in rows if r["is_duplicate"])
    corrupt = sum(1 for r in rows if r["is_corrupt_or_empty"])
    review = sum(1 for r in rows if r["final_label"] == "REVIEW")
    unknown = sum(1 for r in rows if r["final_label"] == "UNKNOWN")
    padding = sum(1 for r in rows if r["needs_padding"])

    print(f"Total escanejats:        {len(rows)}")
    print(f"Duplicats detectats:     {dup}")
    print(f"Corruptes/buits (0.0s):  {corrupt}")
    print(f"Pendents de revisio:     {review}  (respiratorysounds, insidesmallroom)")
    print(f"Etiqueta desconeguda:    {unknown}")
    print(f"Necessiten padding <1s:  {padding}")
    print(f"Mantinguts per entrenar: {len(kept)}")
    print()
    print("Distribucio final (nomes els mantinguts, despres del cap):")
    for label, n in Counter(r["final_label"] for r in kept).most_common():
        print(f"  {label:20s} {n}")

    if unknown:
        unknown_labels = sorted(
            {r["orig_label"] for r in rows if r["final_label"] == "UNKNOWN"}
        )
        print()
        print(f"AVIS: {unknown} fitxers tenen una etiqueta que no apareix a LABEL_MAP:")
        for lbl in unknown_labels:
            n = sum(1 for r in rows if r["orig_label"] == lbl)
            print(f"  - {lbl}  ({n} fitxers)")
        print("Decideix a quina classe final mapegen (o None per descartar-les)")
        print("i afegeix-les a LABEL_MAP abans de donar per bo el manifest.")
        print("Aquests fitxers queden exclosos de 'keep_for_training' fins que ho facis.")


# ---------------------------------------------------------------------------
if __name__ == "__main__":
    dataset_root = sys.argv[1] if len(sys.argv) > 1 else "./dataset"
    output_csv = sys.argv[2] if len(sys.argv) > 2 else "manifest.csv"
    build_manifest(dataset_root, output_csv)
