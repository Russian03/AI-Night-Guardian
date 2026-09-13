import json
import os
import time
from collections import deque

import numpy as np
import paho.mqtt.client as mqtt
from edge_impulse_linux.audio import AudioImpulseRunner

IDENTITY_PATH = os.path.join(os.path.dirname(__file__), "device_identity.json")
STATE_PATH = os.path.join(os.path.dirname(__file__), "listening_state.json")

# --- Configuración ---
EIM_PATH = os.path.join(
    os.path.dirname(__file__),
    "granny-guardians-fr-linux-aarch64-v8-impulse-#1.eim",
)
AUDIO_DEVICE_ID = 8  # "default" - único dispositivo compatible detectado

# Cada cuánto se comprueba el estado del interruptor mientras se clasifica.
# El runner entrega ~16 trozos/s: leer el fichero en cada uno sería absurdo.
STATE_CHECK_SECONDS = 1.0

# Espera entre comprobaciones cuando la escucha está apagada.
IDLE_POLL_SECONDS = 2.0

# --- VAD (Voice Activity Detection) por energía ---------------------------
# El modelo NO ha visto silencio durante el entrenamiento: todos los pasos
# del pipeline de datos conservan solo fragmentos con sonido audible. Al
# recibir silencio, el softmax reparte la probabilidad entre las clases
# existentes y dispara "impacte" con confianza alta sobre una habitación
# vacía. El VAD corta ese caso antes de llegar al modelo.
#
# Medido en la grabación de 15 min de la habitación:
#   RMS mediana        0.00074  (-62.6 dBFS)  -> ~24 en enteros de 16 bits
#   RMS percentil 95   0.00121  (-58.4 dBFS)  -> ~40 en enteros de 16 bits
# Umbral = 2x el percentil 95 del fondo. Subirlo hasta 150-200 es seguro si
# los eventos reales dan valores mucho más altos (comprobar con el log).
SILENCE_RMS = 80

# Poner a True SOLO puntualmente para calibrar. El runner entrega ~16
# trozos por segundo, asi que imprimir en cada uno satura la consola y
# ralentiza el bucle hasta el punto de no seguir el ritmo del audio en
# tiempo real (la cola crece y las clasificaciones acaban correspondiendo a
# audio de hace minutos). En funcionamiento normal debe estar en False.
DEBUG_RMS = False

# El runner NO entrega la ventana de 1s que clasifica el modelo, sino
# trozos de ~64 ms. Calcular el RMS sobre 64 ms da valores erraticos (un
# trozo puede caer en una pausa o justo sobre un clic). Acumulamos los
# ultimos trozos para medir la energia sobre aproximadamente el mismo
# segundo que ve el modelo.
VAD_WINDOW_SEC = 1.0
SAMPLE_RATE = 16000

# --- Umbrales por clase ---------------------------------------------------
# Un umbral único de 0.85 es demasiado alto para las clases críticas: el
# modelo es menos confiado en veu_angoixa (F1 0.66) que en impacte (0.79) o
# tos (0.81), así que con 0.85 los gritos casi nunca dispararían. En un
# sistema de seguridad vale más una falsa alarma que un evento perdido.
CONFIDENCE_THRESHOLDS = {
    "veu_angoixa": 0.45,
    "impacte": 0.55,
    "tos": 0.65,
}
DEFAULT_THRESHOLD = 0.85

# Etiquetas que nunca generan aviso. Añadir "silenci" cuando se despliegue
# el modelo reentrenado con esa clase.
IGNORED_LABELS = {"normal", "silenci"}

# --- Refractario ----------------------------------------------------------
# Antes se comparaba solo con el ÚLTIMO evento emitido, así que la secuencia
# impacte -> tos -> impacte dejaba pasar el segundo impacte de inmediato
# (era el caso de las 6 notificaciones en un minuto). Ahora se guarda un
# timestamp por clase, de modo que cada clase tiene su propio refractario.
DEBOUNCE_SECONDS = 60

with open(IDENTITY_PATH, "r") as f:
    identity = json.load(f)

DEVICE_ID = identity["device_id"]
ROOM_NAME = identity.get("room_name", "Sin nombre")
BROKER = "broker.hivemq.com"
PORT = 1883
TOPIC_EVENTOS = f"residencia/{DEVICE_ID}/eventos"

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"{DEVICE_ID}-audio")


def on_connect(client, userdata, flags, reason_code, properties):
    print(f"[MQTT audio] Conectado al broker, codigo: {reason_code}")


client.on_connect = on_connect
client.connect(BROKER, PORT, keepalive=60)
client.loop_start()


def _read_listening_state():
    """True = escucha activa. Ante cualquier duda, activa: en un sistema de
    seguridad el fallo seguro es seguir vigilando, no dejar de hacerlo."""
    try:
        with open(STATE_PATH, "r") as f:
            return bool(json.load(f).get("listening", True))
    except FileNotFoundError:
        return True
    except (json.JSONDecodeError, OSError):
        # Fichero a medio escribir: se conserva el estado anterior en la
        # siguiente comprobación, no se apaga la escucha por un error de E/S.
        return True


def _rms(samples):
    """RMS en enteros de 16 bits (0 = silencio absoluto)."""
    if samples.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(samples.astype(np.float64) ** 2)))


def _publish_event(event_type, confidence):
    event = {
        "v": 1,
        "type": "event",
        "device_id": DEVICE_ID,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "payload": {
            "room": ROOM_NAME,
            "event_type": event_type,
            "confidence": round(confidence, 2),
            "detected_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        },
    }
    client.publish(TOPIC_EVENTOS, json.dumps(event), qos=1)
    print(f"[EVENTO enviado] {event}")


class ListeningDisabled(Exception):
    """El interruptor se ha apagado: hay que cerrar micro y modelo."""


def classify_session():
    """Carga modelo + micro y clasifica hasta que se apague la escucha o falle.

    Al salir de esta función (por cualquier vía) el bloque `with` cierra el
    runner: esto termina el proceso del .eim y libera el dispositivo de
    audio. Es lo que realmente baja el consumo de CPU y la temperatura;
    limitarse a ignorar los resultados no ahorra nada.
    """
    print(f"[AI Night Guardian] Cargando modelo: {EIM_PATH}")
    with AudioImpulseRunner(EIM_PATH) as runner:
        model_info = runner.init()
        labels = model_info["model_parameters"]["labels"]
        print(f"[AI Night Guardian] Modelo cargado. Clases: {labels}")
        print(f"[AI Night Guardian] VAD: umbral RMS = {SILENCE_RMS}")
        print("[ESCUCHA] Micrófono e inferencia ACTIVOS")

        # una marca de tiempo por clase, no una global
        last_event_ts = {}

        # buffer circular con los ultimos trozos de audio, para medir el RMS
        # sobre ~1s en vez de sobre los 64 ms que entrega el runner
        audio_buffer = deque()
        buffered_samples = 0
        target_samples = int(VAD_WINDOW_SEC * SAMPLE_RATE)

        last_state_check = time.time()

        for res, audio in runner.classifier(device_id=AUDIO_DEVICE_ID):

            # --- Interruptor: comprobar como mucho una vez por segundo ---
            now = time.time()
            if now - last_state_check >= STATE_CHECK_SECONDS:
                last_state_check = now
                if not _read_listening_state():
                    print("[ESCUCHA] Apagando micrófono y descargando modelo...")
                    raise ListeningDisabled()

            chunk = np.frombuffer(audio, dtype=np.int16)
            audio_buffer.append(chunk)
            buffered_samples += chunk.size
            while buffered_samples - audio_buffer[0].size >= target_samples:
                buffered_samples -= audio_buffer.popleft().size

            # --- VAD: descartar silencio ANTES de mirar la clasificación ---
            rms = _rms(np.concatenate(audio_buffer))
            if DEBUG_RMS:
                print(f"[AUDIO] RMS={rms:7.1f}  ({buffered_samples} mostres)"
                      f"{'  descartado por VAD' if rms < SILENCE_RMS else ''}")
            if rms < SILENCE_RMS:
                continue

            scores = res["result"]["classification"]
            top_label = max(scores, key=scores.get)
            top_score = scores[top_label]
            print(f"[AI] TOP: {top_label} = {top_score:.3f}  (RMS={rms:.0f})")

            if top_label in IGNORED_LABELS:
                continue

            threshold = CONFIDENCE_THRESHOLDS.get(top_label, DEFAULT_THRESHOLD)
            if top_score < threshold:
                continue

            # --- Refractario por clase ---
            if time.time() - last_event_ts.get(top_label, 0.0) < DEBOUNCE_SECONDS:
                continue
            last_event_ts[top_label] = time.time()

            _publish_event(top_label, top_score)


def wait_until_enabled():
    """Bucle de reposo: ni micro ni modelo cargados, consumo mínimo."""
    print("[ESCUCHA] Micrófono e inferencia DETENIDOS. Esperando activación...")
    while not _read_listening_state():
        time.sleep(IDLE_POLL_SECONDS)
    print("[ESCUCHA] Activación recibida. Reiniciando modelo...")


def main():
    """
    Reintenta indefinidamente. Así el script puede lanzarse desde ya
    (aunque el .eim aún no esté copiado o el micro USB no esté conectado)
    y arrancará solo en cuanto ambas cosas estén disponibles, sin tener
    que tocar main.py ni reiniciar nada a mano.

    El mismo bucle gestiona el interruptor de escucha: apagarlo cierra el
    runner y se entra en reposo; encenderlo vuelve a cargar el modelo.
    """
    RETRY_SECONDS = 10
    while True:
        # Si está apagado, ni siquiera se intenta abrir el micro.
        if not _read_listening_state():
            wait_until_enabled()
            continue

        try:
            classify_session()

        except ListeningDisabled:
            # Salida limpia y esperada: el `with` ya ha cerrado el runner.
            wait_until_enabled()

        except KeyboardInterrupt:
            raise

        except Exception as e:
            print(f"[AI Night Guardian] Audio no disponible todavia ({e}). "
                  f"Reintentando en {RETRY_SECONDS}s...")
            time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Deteniendo...")
    finally:
        client.loop_stop()
        client.disconnect()