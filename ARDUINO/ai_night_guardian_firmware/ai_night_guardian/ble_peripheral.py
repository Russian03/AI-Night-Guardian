from bluezero import peripheral
import json
import os
import subprocess

IDENTITY_PATH = os.path.join(os.path.dirname(__file__), "device_identity.json")

with open(IDENTITY_PATH, "r") as f:
    identity = json.load(f)

DEVICE_NAME = identity["device_id"]

SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
CHAR_TX_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
CHAR_RX_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
CHAR_STATUS_UUID = "6e400004-b5a3-f393-e0a9-e50e24dcca9e"
WIFI_IFACE = "wlan0"

status_obj = None


def on_status_notify(notifying, characteristic):
    global status_obj
    if notifying:
        status_obj = characteristic
    else:
        status_obj = None


def notify_status(state, extra=None):
    payload = {"type": "wifi_status", "state": state}
    if extra:
        payload.update(extra)
    data = json.dumps(payload).encode("utf-8")
    print(f"[STATUS] {payload}")
    if status_obj is not None:
        status_obj.set_value(list(data))
    else:
        print("(nadie suscrito a STATUS todavia, no se envia notify)")


def save_room_name(room_name):
    identity["room_name"] = room_name
    with open(IDENTITY_PATH, "w") as f:
        json.dump(identity, f, indent=2)
    print(f"[IDENTITY] room_name guardado: {room_name}")


def connect_wifi(ssid, password):
    notify_status("connecting")

    subprocess.run(["nmcli", "connection", "delete", ssid],
                    capture_output=True, text=True)

    result = subprocess.run(
        ["nmcli", "connection", "add",
         "type", "wifi",
         "ifname", WIFI_IFACE,
         "con-name", ssid,
         "ssid", ssid,
         "wifi-sec.key-mgmt", "wpa-psk",
         "wifi-sec.psk", password],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        notify_status("failed", {"error": ("add: " + result.stderr.strip())[:150]})
        return

    result = subprocess.run(
        ["nmcli", "connection", "up", ssid],
        capture_output=True, text=True, timeout=30
    )

    if result.returncode == 0:
        ip_result = subprocess.run(
            ["nmcli", "-g", "IP4.ADDRESS", "device", "show", WIFI_IFACE],
            capture_output=True, text=True
        )
        ip = ip_result.stdout.strip().split("/")[0] if ip_result.stdout.strip() else "unknown"
        notify_status("connected", {"ip": ip})
    else:
        notify_status("failed", {"error": ("up: " + result.stderr.strip())[:150]})


def on_tx_write(value, options):
    raw = bytes(value).decode("utf-8", errors="ignore")
    print(f"[BLE RX de app] {raw}")
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        print("JSON invalido recibido")
        return

    if msg.get("type") == "wifi_provision":
        room_name = msg.get("room_name", "Sin nombre")
        save_room_name(room_name)
        connect_wifi(msg.get("ssid"), msg.get("password"))


adapter_address = list(peripheral.adapter.Adapter.available())[0].address

ble_device = peripheral.Peripheral(adapter_address, local_name=DEVICE_NAME)

ble_device.add_service(srv_id=1, uuid=SERVICE_UUID, primary=True)

ble_device.add_characteristic(
    srv_id=1, chr_id=1, uuid=CHAR_TX_UUID,
    value=[], notifying=False,
    flags=['write'],
    write_callback=on_tx_write,
)

ble_device.add_characteristic(
    srv_id=1, chr_id=2, uuid=CHAR_RX_UUID,
    value=[], notifying=True,
    flags=['notify'],
)

ble_device.add_characteristic(
    srv_id=1, chr_id=3, uuid=CHAR_STATUS_UUID,
    value=[0x00], notifying=True,
    flags=['read', 'notify'],
    notify_callback=on_status_notify,
)

print(f"[AI Night Guardian] Anunciando BLE como: {DEVICE_NAME}")
print(f"[AI Night Guardian] Service UUID: {SERVICE_UUID}")

ble_device.publish()
