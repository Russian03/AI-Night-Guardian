import time
import subprocess
import os

from arduino.app_utils import App
from device_identity import load_or_create_identity, generate_qr

identity = load_or_create_identity()
qr_path = generate_qr(identity)

print(f"[AI Night Guardian] device_id: {identity['device_id']}")
print(f"[AI Night Guardian] QR guardado en: {qr_path}")

mqtt_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "ai_night_guardian", "mqtt_publisher.py")
subprocess.Popen(["python3", mqtt_path])
print("MQTT publisher launched")

def loop():
    """Se ejecuta repetidamente. BLE advertising se añade en el siguiente paso."""
    time.sleep(10)

App.run(user_loop=loop)