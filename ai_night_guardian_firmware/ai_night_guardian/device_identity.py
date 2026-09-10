"""
Genera y persiste device_id y provisioning_key unicos del dispositivo,
y produce el QR de aprovisionamiento.
"""
import json
import os
import secrets
import uuid
import qrcode

IDENTITY_PATH = os.path.join(os.path.dirname(__file__), "device_identity.json")
QR_PATH = os.path.join(os.path.dirname(__file__), "provisioning_qr.png")

MODEL = "UnoQ-v1"
FW_MIN_VERSION = "0.1.0"


def _generate_device_id():
    suffix = uuid.uuid4().hex[:6].upper()
    return f"AING-{suffix}"


def load_or_create_identity():
    if os.path.exists(IDENTITY_PATH):
        with open(IDENTITY_PATH, "r") as f:
            return json.load(f)

    identity = {
        "device_id": _generate_device_id(),
        "provisioning_key": secrets.token_hex(16),
        "model": MODEL,
        "fw_min_version": FW_MIN_VERSION,
    }
    with open(IDENTITY_PATH, "w") as f:
        json.dump(identity, f, indent=2)
    return identity


def generate_qr(identity):
    payload = json.dumps({
        "device_id": identity["device_id"],
        "provisioning_key": identity["provisioning_key"],
        "model": identity["model"],
        "fw_min_version": identity["fw_min_version"],
    })
    img = qrcode.make(payload)
    img.save(QR_PATH)
    return QR_PATH
