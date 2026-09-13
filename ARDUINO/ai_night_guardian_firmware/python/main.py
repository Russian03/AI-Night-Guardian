import time
import subprocess
import os

from arduino.app_utils import App
from device_identity import load_or_create_identity, generate_qr

identity = load_or_create_identity()
# qr_path = generate_qr(identity)

print(f"[AI Night Guardian] device_id: {identity['device_id']}")
# print(f"[AI Night Guardian] QR guardado en: {qr_path}")

base_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "ai_night_guardian")

# BLE
ble_path = os.path.join(base_dir, "bleperipheral.py")
subprocess.Popen(["python3", ble_path])
print("BLE peripheral launched")

# MQTT
mqtt_path = os.path.join(base_dir, "mqtt_publisher.py")
subprocess.Popen(["python3", mqtt_path])
print("MQTT publisher launched")

# AUDIO / IA
# nice 10: la inferencia es la carga dominante del sistema y no cede CPU
# voluntariamente, lo que hacía expirar las peticiones 'read_sensors' al MCU
# (temp_c y lux llegaban como null). Con menor prioridad, el planificador
# atiende primero al hilo de sensores, que es cortísimo, sin que la
# clasificación pierda tiempo real apreciable.
audio_path = os.path.join(base_dir, "audio_publisher.py")
subprocess.Popen(["nice", "-n", "10", "python3", audio_path])
print("Audio publisher launched (nice 10)")


def loop():
    """Se ejecuta repetidamente. BLE advertising se añade en el siguiente paso."""
    time.sleep(10)


App.run(user_loop=loop)