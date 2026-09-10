import json
import os
import paho.mqtt.client as mqtt

IDENTITY_PATH = os.path.join(os.path.dirname(__file__), "device_identity.json")
STATE_PATH = os.path.join(os.path.dirname(__file__), "listening_state.json")

with open(IDENTITY_PATH, "r") as f:
    identity = json.load(f)

DEVICE_ID = identity["device_id"]
BROKER = "broker.hivemq.com"
PORT = 1883
TOPIC_CONFIG = f"residencia/{DEVICE_ID}/config"


def save_listening_state(listening):
    with open(STATE_PATH, "w") as f:
        json.dump({"listening": listening}, f)
    print(f"[CONFIG] listening = {listening}")
    # TODO: cuando exista el modelo de IA real, aqui se arranca/para la inferencia.


def on_connect(client, userdata, flags, reason_code, properties):
    print(f"[MQTT config] Conectado, codigo: {reason_code}")
    client.subscribe(TOPIC_CONFIG, qos=1)


def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload.decode("utf-8"))
    except json.JSONDecodeError:
        print("Mensaje config invalido")
        return

    if payload.get("type") == "config":
        listening = payload.get("payload", {}).get("listening")
        if listening is not None:
            save_listening_state(listening)


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"{DEVICE_ID}-config")
client.on_connect = on_connect
client.on_message = on_message
client.connect(BROKER, PORT, keepalive=60)

print(f"[AI Night Guardian] Escuchando config en: {TOPIC_CONFIG}")
client.loop_forever()
