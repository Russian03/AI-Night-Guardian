import json
import time
import os
import paho.mqtt.client as mqtt

from arduino.app_utils import Bridge

IDENTITY_PATH = os.path.join(os.path.dirname(__file__), "device_identity.json")
STATE_PATH = os.path.join(os.path.dirname(__file__), "listening_state.json")

with open(IDENTITY_PATH, "r") as f:
    identity = json.load(f)

DEVICE_ID = identity["device_id"]
ROOM_NAME = identity.get("room_name", "Sin nombre")
BROKER = "broker.hivemq.com"
PORT = 1883
TOPIC_HEARTBEAT = f"residencia/{DEVICE_ID}/heartbeat"

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=DEVICE_ID)


def _read_listening_state():
    try:
        with open(STATE_PATH, "r") as f:
            return json.load(f).get("listening", True)
    except FileNotFoundError:
        return True


def on_connect(client, userdata, flags, reason_code, properties):
    print(f"[MQTT] Conectado al broker, codigo: {reason_code}")


client.on_connect = on_connect
client.connect(BROKER, PORT, keepalive=60)
client.loop_start()

print(f"[AI Night Guardian] Publicando en: {TOPIC_HEARTBEAT}")
print(f"[AI Night Guardian] device_id: {DEVICE_ID} / room: {ROOM_NAME}")

uptime_start = time.time()

def _read_sensors():
    try:
        data = Bridge.call("read_sensors")
        return json.loads(data)
    except Exception as e:
        print(f"[SENSORES] Error: {e}")
        return {
            "temp_c": None,
            "humidity": None,
            "lux": None
        }

try:
    while True:
        sensors = _read_sensors()

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
                #"humidity": sensors["humidity"],
                "lux": sensors["lux"],
                "listening": _read_listening_state()
            }
        }
        client.publish(TOPIC_HEARTBEAT, json.dumps(heartbeat), qos=1)
        print(f"[HEARTBEAT enviado] {heartbeat}")
        time.sleep(15)
except KeyboardInterrupt:
    print("Deteniendo...")
    client.loop_stop()
    client.disconnect()
