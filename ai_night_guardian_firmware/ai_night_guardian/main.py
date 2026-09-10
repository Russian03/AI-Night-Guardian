import time
from device_identity import load_or_create_identity, generate_qr

identity = load_or_create_identity()
qr_path = generate_qr(identity)

print(f"[AI Night Guardian] device_id: {identity['device_id']}")
print(f"[AI Night Guardian] QR guardado en: {qr_path}")

while True:
    time.sleep(10)
