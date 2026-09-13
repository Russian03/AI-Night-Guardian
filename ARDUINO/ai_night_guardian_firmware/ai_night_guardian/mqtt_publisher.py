import json
import time
import os
import threading
import paho.mqtt.client as mqtt

from arduino.app_utils import Bridge


IDENTITY_PATH = os.path.join(
    os.path.dirname(__file__),
    "device_identity.json"
)

STATE_PATH = os.path.join(
    os.path.dirname(__file__),
    "listening_state.json"
)


with open(IDENTITY_PATH, "r") as f:
    identity = json.load(f)


DEVICE_ID = identity["device_id"]
ROOM_NAME = identity.get("room_name", "Sin nombre")

BROKER = "broker.hivemq.com"
PORT = 1883

TOPIC_HEARTBEAT = f"residencia/{DEVICE_ID}/heartbeat"
TOPIC_CONFIG = f"residencia/{DEVICE_ID}/config"

# Cada cuánto se intenta leer los sensores (en el hilo lector).
SENSOR_POLL_SECONDS = 5

# Tras un fallo, reintentar pronto: un fallo no debe costar un ciclo entero.
SENSOR_RETRY_SECONDS = 1

# Antigüedad máxima de una lectura antes de considerarla inservible.
# Pasado este margen se publica None: mejor un hueco honesto que un dato falso.
SENSOR_MAX_AGE_SECONDS = 60

HEARTBEAT_SECONDS = 5


client = mqtt.Client(
    mqtt.CallbackAPIVersion.VERSION2,
    client_id=DEVICE_ID
)

mqtt_connected = False
mqtt_loop_started = False
last_mqtt_attempt = 0
MQTT_RETRY_SECONDS = 10


# =====================================================
# Estado de escucha (interruptor de micrófono)
# =====================================================

state_lock = threading.Lock()


def _read_listening_state():
    """True = escucha activa. Ante cualquier duda, activa: en un sistema de
    seguridad el fallo seguro es seguir vigilando, no dejar de hacerlo."""
    try:
        with open(STATE_PATH, "r") as f:
            return bool(json.load(f).get("listening", True))
    except FileNotFoundError:
        return True
    except (json.JSONDecodeError, OSError):
        return True


def _write_listening_state(listening):
    """Escritura atómica: audio_publisher lee este fichero constantemente y
    no debe encontrarse nunca un JSON a medio escribir."""
    tmp = STATE_PATH + ".tmp"
    with state_lock:
        with open(tmp, "w") as f:
            json.dump({"listening": bool(listening)}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATE_PATH)

    print(f"[CONFIG] Escucha acústica -> {'ACTIVA' if listening else 'DETENIDA'}")


def on_message(client, userdata, msg):
    """Mensajes de configuración enviados por la app.

    Formato esperado:
        {"type": "config", "payload": {"listening": false}}
    """
    try:
        data = json.loads(msg.payload.decode("utf-8"))
        payload = data.get("payload", {})

        if "listening" in payload:
            _write_listening_state(payload["listening"])

    except Exception as e:
        print(f"[CONFIG] Mensaje no válido: {e}")


def on_connect(client, userdata, flags, reason_code, properties):
    global mqtt_connected

    if reason_code == 0:
        mqtt_connected = True
        print("[MQTT] Conectado al broker")

        # Resuscribirse en cada (re)conexión: las suscripciones no
        # sobreviven a una caída de sesión.
        client.subscribe(TOPIC_CONFIG, qos=1)
        print(f"[MQTT] Suscrito a {TOPIC_CONFIG}")

    else:
        mqtt_connected = False
        print(f"[MQTT] Error de conexión. Código: {reason_code}")


def on_disconnect(client, userdata, disconnect_flags, reason_code, properties):
    global mqtt_connected

    mqtt_connected = False
    print(f"[MQTT] Desconectado. Código: {reason_code}")


client.on_connect = on_connect
client.on_disconnect = on_disconnect
client.on_message = on_message


# =====================================================
# Lectura de sensores en hilo aparte
# =====================================================
#
# Bridge.call() es bloqueante y su timeout es de 10 s. Si se llama desde
# el bucle principal, un fallo detiene también el heartbeat. Aislándolo
# en un hilo, el heartbeat mantiene su cadencia pase lo que pase.

class SensorCache:

    def __init__(self):
        self._lock = threading.Lock()
        self._values = {"temp_c": None, "humidity": None, "lux": None}
        self._last_ok = 0.0
        self._fail_streak = 0

    def update(self, values):
        with self._lock:
            self._values = values
            self._last_ok = time.time()
            self._fail_streak = 0

    def mark_failure(self):
        with self._lock:
            self._fail_streak += 1
            return self._fail_streak

    def snapshot(self):
        """Devuelve (valores, antigüedad_en_segundos).

        Si la última lectura válida es demasiado antigua, devuelve None en
        todos los campos en lugar de un dato obsoleto.
        """
        with self._lock:
            if self._last_ok == 0.0:
                return {"temp_c": None, "humidity": None, "lux": None}, None

            age = time.time() - self._last_ok

            if age > SENSOR_MAX_AGE_SECONDS:
                return {"temp_c": None, "humidity": None, "lux": None}, int(age)

            return dict(self._values), int(age)


sensor_cache = SensorCache()
stop_event = threading.Event()


def sensor_worker():
    # El hilo pasa casi todo el tiempo bloqueado esperando al MCU. Elevar su
    # prioridad no roba CPU real al audio, solo asegura que cuando la
    # respuesta llega, se procesa sin esperar turno. Requiere privilegios;
    # sin ellos el nice del proceso de audio ya es suficiente.
    try:
        os.nice(-5)
    except (PermissionError, OSError):
        pass

    while not stop_event.is_set():
        try:
            raw = Bridge.call("read_sensors")
            data = json.loads(raw)

            sensor_cache.update({
                "temp_c": data.get("temp_c"),
                "humidity": data.get("humidity"),
                "lux": data.get("lux"),
            })

            stop_event.wait(SENSOR_POLL_SECONDS)

        except Exception as e:
            streak = sensor_cache.mark_failure()

            # Solo avisar en el primer fallo y luego cada 10, para no
            # inundar el log cuando el MCU está caído.
            if streak == 1 or streak % 10 == 0:
                print(f"[SENSORES] Fallo #{streak}: {e}")

            stop_event.wait(SENSOR_RETRY_SECONDS)


sensor_thread = threading.Thread(
    target=sensor_worker,
    name="sensor-reader",
    daemon=True
)
sensor_thread.start()


# =====================================================

def try_connect_mqtt():
    global last_mqtt_attempt, mqtt_loop_started

    now = time.time()

    # Evitar intentar continuamente
    if now - last_mqtt_attempt < MQTT_RETRY_SECONDS:
        return

    last_mqtt_attempt = now

    try:
        print("[MQTT] Intentando conectar...")

        client.connect(
            BROKER,
            PORT,
            keepalive=60
        )

        # loop_start() solo una vez en toda la vida del proceso.
        if not mqtt_loop_started:
            client.loop_start()
            mqtt_loop_started = True

    except Exception as e:
        print(f"[MQTT] Sin Internet/DNS todavía: {e}")


print(f"[AI Night Guardian] MQTT preparado")
print(f"[AI Night Guardian] Broker: {BROKER}:{PORT}")
print(f"[AI Night Guardian] device_id: {DEVICE_ID}")
print(f"[AI Night Guardian] room: {ROOM_NAME}")


uptime_start = time.time()


try:
    while True:

        # -------------------------------------------------
        # 1. Intentar MQTT si todavía no estamos conectados
        # -------------------------------------------------

        if not mqtt_connected:
            try_connect_mqtt()


        # -------------------------------------------------
        # 2. Leer sensores desde la caché (no bloquea)
        # -------------------------------------------------

        sensors, sensor_age = sensor_cache.snapshot()


        # -------------------------------------------------
        # 3. Crear heartbeat
        # -------------------------------------------------

        heartbeat = {
            "v": 1,
            "type": "heartbeat",
            "device_id": DEVICE_ID,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),

            "payload": {
                "room": ROOM_NAME,
                "fw_version": "0.1.0",
                "uptime_s": int(time.time() - uptime_start),
                "rssi": -55,
                "temp_c": sensors["temp_c"],
                "lux": sensors["lux"],
                "sensor_age_s": sensor_age,
                "listening": _read_listening_state()
            }
        }


        # -------------------------------------------------
        # 4. Enviar solamente si MQTT está conectado
        # -------------------------------------------------

        if mqtt_connected:

            try:
                result = client.publish(
                    TOPIC_HEARTBEAT,
                    json.dumps(heartbeat),
                    qos=1
                )

                print(f"[HEARTBEAT enviado] {heartbeat}")

            except Exception as e:
                print(f"[MQTT] Error publicando heartbeat: {e}")
                mqtt_connected = False

        else:

            print("[MQTT] Sin conexión. Heartbeat no enviado.")


        time.sleep(HEARTBEAT_SECONDS)


except KeyboardInterrupt:

    print("Deteniendo...")

    stop_event.set()
    sensor_thread.join(timeout=2)

    try:
        client.loop_stop()
        client.disconnect()
    except Exception:
        pass