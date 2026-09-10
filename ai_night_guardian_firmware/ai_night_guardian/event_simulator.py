import json
import time
import os
import sys
import paho.mqtt.client as mqtt

IDENTITY_PATH = os.path.join(os.path.dirname(__file__), "device_identity.json")

with open(IDENTITY_PATH, "r") as f:
    identity = json.load(f)

DEVICE_ID = identity["device_id"]
ROOM_NAME = identity.get("room_name", "Sin nombre")
BROKER = "broker.hivemq.com"
PORT = 1883
TOPIC_EVENTS = f"residencia/{DEVICE_ID}/eventos"

client = mqtt.Client(
    mqtt.CallbackAPIVersion.VERSION2,
    client_id=f"{DEVICE_ID}-events",
    clean_session=False,
)
client.connect(BROKER, PORT, keepalive=60)
client.loop_start()


def send_event(event_type, confidence=0.92):
    event = {
        "v": 1,
        "type": "event",
        "device_id": DEVICE_ID,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "payload": {
            "room": ROOM_NAME,
            "event_type": event_type,
            "confidence": confidence,
            "detected_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }
    }
    client.publish(TOPIC_EVENTS, json.dumps(event), qos=1)
    print(f"[EVENTO enviado] {event}")


if __name__ == "__main__":
    event_type = sys.argv[1] if len(sys.argv) > 1 else "caida"
    send_event(event_type)
    time.sleep(2)
    client.loop_stop()
    client.disconnect()
