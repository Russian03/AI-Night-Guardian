# AI Night Guardian

> Acoustic detection of night-time incidents in care homes, running locally
> on-device and **without recording or storing any audio**.

Submitted to **HackEstiu 2026** (Universitat Politècnica de Catalunya).

- **Team:** Jan Díaz Carreras-Candi · Guillem Guilera Aulet · Joan Montobbio Palmer
- **Affiliation:** ETSETB — Universitat Politècnica de Catalunya (UPC), Barcelona
- **Hardware:** Arduino UNO Q + Modulino (temperature / light) + USB-C lavalier microphone + 3D printed enclosure
- **License:** MIT — see [`LICENSE`](LICENSE)
- **Arduino Project Hub:** *[add link]*
- **Edge Impulse™ project (public):** *[add link]*
- **Demo video:** *[add link]*

---

## Contents

1. [The problem](#1-the-problem)
2. [The solution](#2-the-solution)
3. [Privacy by design](#3-privacy-by-design)
4. [Architecture](#4-architecture)
5. [Hardware](#5-hardware)
6. [Repository layout](#6-repository-layout)
7. [The dataset](#7-the-dataset)
8. [The model](#8-the-model)
9. [On-device decision logic](#9-on-device-decision-logic)
10. [Running it](#10-running-it)
11. [Communication protocols](#11-communication-protocols)
12. [Current status](#12-current-status)
13. [Known limitations](#13-known-limitations)

---

## 1. The problem

In care homes, night staff work by rounds: they walk into each room to
check that the resident is all right. Depending on the facility, a given
room gets a visit roughly once an hour.

That means there is up to an hour in which nobody knows what is happening
inside a room. If someone falls, if someone is in distress, it gets noticed
on the next round — not when it happens.

The obvious technical fix is a camera or an always-on microphone. But these
are people's bedrooms, and continuous recording in a resident's room is not
something anyone should accept. Any system that goes in there has to work
without keeping the audio.

## 2. The solution

**AI Night Guardian** is a device built on an Arduino UNO Q that runs a
neural network **locally** to classify sounds inside a room. It doesn't
replace the rounds — it covers the time between them.

The model distinguishes five kinds of sound, chosen so that each one maps
to a different action:

| Class | What it covers | Device action |
|---|---|---|
| `impacte` | Impacts, falls, doors | Alert — possible incident |
| `veu_angoixa` | Screaming, crying, distress | Alert — immediate attention |
| `tos` | Coughing fits | Alert — low priority |
| `normal` | Speech, snoring, rain, traffic, alarms | Nothing |
| `silenci` | A quiet room | Nothing |

When it detects an incident, the device records the time and the type and
publishes a notification to the staff's mobile app, so carers can
prioritise the rooms that actually need attention.

**Additional, non-acoustic alerts:**

- **Ambient light changes** (lights switched on or off) via the Modulino light sensor.
- **Temperature outside a configurable range** (e.g. `[20 °C, 30 °C]`), particularly relevant during heatwaves.

Because it is a **low-cost system with local processing**, it can be
deployed in care homes, assisted-living facilities and even in the homes of
older people living alone.

## 3. Privacy by design

This is the core constraint of the project and the reason it is legally
deployable in a care home under GDPR.

- **No personal or biometric data is processed or stored.**
- The room's acoustic signal is captured **straight into memory**.
- Once the neural network has run inference, the **audio window is immediately and irreversibly discarded**, having never been written anywhere.
- The device **does not transmit audio** outside the room.
- The only thing that leaves the device is **text metadata**:

```
Room 14 — 02:40 — impact detected
```

Legally, the system behaves as an **automated emergency sensor**, not as a
listening microphone.

The app also includes a per-room **listening switch**, which lets staff
pause inference at any time from their phone (MQTT `config` topic, see §11).

## 4. Architecture

```
┌──────────────────────────────── ROOM ───────────────────────────────────┐
│                                                                         │
│   USB-C microphone ──► Arduino UNO Q                                    │
│                        ├── sketch.ino  (Zephyr / MCU)                   │
│                        │    · reads Modulino: temperature, light        │
│                        │    · exposes read_sensors() via RouterBridge   │
│                        │                                                 │
│                        └── Python (Linux side of the UNO Q)             │
│                             · device_identity.py → device_id + QR        │
│                             · ble_peripheral.py  → WiFi provisioning     │
│                             · mqtt_publisher.py  → heartbeat every 15 s  │
│                             · config_listener.py → commands from the app │
│                             · main.py            → Edge Impulse™ inference│
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │  MQTT / TCP 1883
                                   │  residencia/<device_id>/{heartbeat,eventos,config}
                                   ▼
                        ┌────────────────────────┐
                        │  Mobile app (Flutter)  │
                        │  · QR + BLE onboarding │
                        │  · per-room dashboard  │
                        │  · push notifications  │
                        └────────────────────────┘
```

**Incident flow:** microphone → 1 s window in RAM → Mel-filterbank energies
→ **audio window discarded** → inference → if the energy gate, the
confidence threshold and the refractory period all pass, a JSON text
message is published over MQTT → notification on the staff phone.

## 5. Hardware

| Component | Notes |
|---|---|
| **Arduino UNO Q** (4 GB) | Main board; runs Linux (Cortex-A) alongside a Zephyr MCU |
| **T'nB Influence Lapel Microphone USB-C** | Audio capture |
| **USB-C hub** | Connects microphone and power to the board |
| **Modulino Thermo** | Room temperature |
| **Modulino Light** | Ambient light level |
| **3D printed enclosure** | Custom; STL in this repository |

## 6. Repository layout

```
AI-Night-Guardian/
├── ai_night_guardian_firmware/        # Everything that runs on the device
│   ├── sketch/
│   │   ├── sketch.ino                 # MCU: Modulino sensors + RouterBridge
│   │   ├── sketch.yaml                # Build profile (arduino:zephyr)
│   │   └── libraries/
│   ├── ai_night_guardian/             # Python layer (UNO Q Linux side)
│   │   ├── main.py                    # Inference loop: VAD, thresholds, MQTT
│   │   ├── device_identity.py         # device_id, provisioning_key, QR
│   │   ├── ble_peripheral.py          # GATT for WiFi provisioning
│   │   ├── mqtt_publisher.py          # Heartbeat with sensor data
│   │   └── config_listener.py         # Receives {"listening": bool}
│   └── app.yaml
│
├── ai_guardians/                      # Flutter mobile app
│   └── lib/
│       ├── data/                      # mqtt_service, notification_service
│       ├── domain/
│       └── presentation/screens/
│
├── model/                             # Audio model — see model/README.md
│   ├── README.md                      # Pipeline docs + design rationale
│   ├── build_manifest.py              # Labels, dedup, corrupt files, caps
│   ├── materialize_dataset.py         # Manifest -> one folder per class
│   ├── segment_events.py              # Energy-based segmentation
│   ├── yamnet_clean.py                # Semantic segmentation with YAMNet
│   ├── augment_gain.py                # Random gain, level invariance
│   └── prepare_room_audio.py          # Silence class from a real room
│
├── Creació dataset/                   # Extraction from the source datasets
├── dataset_final_16khz/               # 30,487 .wav samples at 16 kHz mono
├── enclosure/                         # 3D printable enclosure (STL)
├── DATASET INFO.pdf                   # Source datasets and extraction method
└── README.md
```

## 7. The dataset

`dataset_final_16khz/` holds **30,487** `.wav` samples, all normalised to
**16 kHz mono**. File names follow the pattern `<class>_<source>_<id>.wav`.

### Sources

| Dataset | Samples | Origin |
|---|---|---|
| [AudioSet](https://research.google.com/audioset/) (Google) | 10,463 | 10 s clips from YouTube |
| [FSD50K](https://zenodo.org/records/4060432) (UPF) | 13,642 | Zenodo |
| [COUGHVID](https://zenodo.org/records/4048312) | 5,902 | Zenodo — verified coughing |
| [ESC-50](https://github.com/karolpiczak/ESC-50) | 480 | GitHub |
| **Total** | **30,487** | |

Extraction methodology is documented in **[`DATASET INFO.pdf`](DATASET%20INFO.pdf)**,
and the extraction scripts are in [`Creació dataset/`](Creaci%C3%B3%20dataset/).

### Why 16 kHz mono

- **16 kHz** is the TinyML standard. By Nyquist it captures up to 8 kHz, and
  human voice, snoring and impacts carry practically all their acoustic
  information below 4 kHz. Using 44.1 kHz would only add useless high
  frequencies and triple the file size.
- **Mono** because the model doesn't need to know which side the sound came
  from, only whether it happened and what it was.

### Processing pipeline

The raw collection is not usable as-is. The scripts in
[`model/`](model/) turn it into the training set; each step is documented
in [`model/README.md`](model/README.md).

Cleaning found substantial problems in the raw data:

| | |
|---|---|
| Exact duplicates (MD5) | 2,634 |
| Corrupt files (0.0 s) | 2,621 |
| Clips shorter than 1 s | 1,540 |

Almost 17% of the collection was unusable before training started.

## 8. The model

Full detail — pipeline, design decisions, every iteration and its numbers —
is in **[`model/README.md`](model/README.md)**. Summary:

**Preprocessing:** Mel-filterbank energies (MFE) over 1-second windows with
a 500 ms stride, 40 filters, 256-point FFT.

**Network:** MobileNetV2 transfer learning (Edge Impulse™ keyword-spotting
block), deployed as an `.eim` binary on the Linux side of the UNO Q at
**10 ms latency and 177 kB of RAM**.

**What actually moved the needle** was the data, not the network:

| Iteration | Accuracy | Change |
|---|---|---|
| 1 | 46.1% | 10 classes |
| 2 | 53.3% | 8 classes |
| 3 | 60.7% | 4 classes, transfer learning |
| 4 | 64.4% | More data on critical classes |
| 5 | 75.5% | YAMNet label cleaning |
| 6 | **76.8%** | Silence class |
| 7 | 73.7% | Gain augmentation |

Two findings worth highlighting:

**31% of the screaming clips contained no screaming.** FSD50K and AudioSet
use weak labels — the tag means the sound appears somewhere in a ten-second
clip, not that it fills it. Filtering the collection through YAMNet, which
classifies 521 sound types every 0.48 s, and keeping only confirmed
fragments took accuracy from 64% to 75% **on less data**.

**The deployed system runs 30 dB below the training clips.** The MFE block
is not level-invariant, and the same event reads −33 or −47 dBFS depending
on distance to the microphone. Rather than matching a level, the model is
trained with random gains so it cannot rely on absolute volume.

Note the last row: gain augmentation **lowers the score and improves the
system**. On the real device the previous version raised occasional impact
alerts during ordinary conversation; this one does not. The validation set
cannot see the difference, because the problem it solves only exists
outside the lab.

## 9. On-device decision logic

The classifier runs twice a second — tens of thousands of inferences per
room per night. Even a small false-positive rate becomes an unusable number
of notifications, so three filters sit between the model and the phone:

**Energy gate (VAD).** If the RMS of the window is below a calibrated
floor, the model is not called at all. Silence never reaches the
classifier, and the board saves the compute.

**Per-class confidence thresholds.** The model is less confident on
distress than on impacts, so a single global threshold either misses
screams or floods on impacts.

**Per-class refractory period.** After an alert for a class, further alerts
for that class are suppressed for a configurable window. One cough during a
coughing fit is worth a notification; eighty are not.

All three are configured at the top of
[`main.py`](ai_night_guardian_firmware/ai_night_guardian/main.py).

### Calibrating a new room

Record ~15 minutes of the room with no incidents and run:

```bash
python model/prepare_room_audio.py recording.wav silenci
```

It reports the RMS levels of the room, which set the energy gate, and
produces 2-second clips that can be added as the `silenci` class for a
room-specific retrain. This takes minutes and is what adapts the system to
a new environment.

## 10. Running it

### 10.1 Device

**Requirements:** Arduino CLI with the `arduino:zephyr` platform, Python
3.11+ on the board's Linux side, `nmcli` (NetworkManager) and BlueZ.

```bash
pip install numpy paho-mqtt qrcode[pil] bluezero

# 1) Build and upload the sketch to the MCU (Modulino + Bridge)
cd ai_night_guardian_firmware/sketch
arduino-cli compile --profile default . && arduino-cli upload -p <PORT> --profile default .

# 2) Generate device identity and provisioning QR
cd ../ai_night_guardian
python3 device_identity.py

# 3) WiFi provisioning over BLE
sudo python3 ble_peripheral.py

# 4) Sensor heartbeats
python3 mqtt_publisher.py

# 5) Inference loop
python3 main.py
```

### 10.2 Mobile app

**Requirements:** Flutter SDK ≥ 3.13.2.

```bash
cd ai_guardians
flutter pub get
flutter run          # or: flutter build apk --release
```

**Onboarding flow:** splash → *Add device* → scan the **QR** shown by the
device (`device_id` + `provisioning_key`) → **BLE scan** → **WiFi + room
name** form → the device connects and publishes its first heartbeat →
**dashboard** with temperature, lux, uptime, last incident and the
listening switch.

Required permissions: Bluetooth, camera (QR), location (needed for BLE
scanning on Android) and notifications.

## 11. Communication protocols

### MQTT

Test broker: `broker.hivemq.com:1883`. All messages are JSON with `v`,
`type`, `device_id`, `ts` and `payload`.

| Topic | Direction | Contents |
|---|---|---|
| `residencia/<device_id>/heartbeat` | device → app | Liveness every 15 s |
| `residencia/<device_id>/eventos` | device → app | Detected incident (QoS 1) |
| `residencia/<device_id>/config` | app → device | Configuration (QoS 1) |

**Event:**

```json
{
  "v": 1, "type": "event", "device_id": "AING-9D67B1",
  "ts": "2026-09-12T02:40:11+0200",
  "payload": {
    "room": "Room 14", "event_type": "impacte",
    "confidence": 0.85, "detected_at": "2026-09-12T02:40:11+0200"
  }
}
```

### BLE provisioning

Nordic UART style service: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`

| Characteristic | UUID | Use |
|---|---|---|
| TX (write) | `…0002-…` | App sends `{"type":"wifi_provision","ssid":…,"password":…,"room_name":…}` |
| RX (notify) | `…0003-…` | Reserved |
| STATUS (read/notify) | `…0004-…` | `{"type":"wifi_status","state":"connecting\|connected\|failed","ip":…}` |

## 12. Current status

### Working

- [x] Full Flutter app: QR + BLE onboarding, WiFi provisioning, device list, live dashboard, local notifications, listening switch.
- [x] Persistent device identity and QR generation.
- [x] MQTT telemetry: heartbeat every 15 s with real temperature and lux via `RouterBridge`.
- [x] Bidirectional configuration channel.
- [x] Dataset of 30,487 samples unified at 16 kHz mono, with a documented and reproducible cleaning pipeline.
- [x] Five-class audio model trained, deployed and running on-device.
- [x] On-device decision logic: energy gate, per-class thresholds, per-class refractory period.
- [x] 3D printed enclosure.

### Pending

- [ ] Temperature and light alerts (the sensors are read; the alert rules are not implemented yet).
- [ ] RTC (DS3231 or NTP) for accurate timestamps without depending on the network.
- [ ] A private MQTT broker with TLS and authentication. `broker.hivemq.com` is public and only suitable for prototyping — this is a blocker for any real deployment.
- [ ] Publish the dataset extraction scripts described in `DATASET INFO.pdf`.

## 13. Known limitations

**A fall and a closing door sound the same.** This is a limitation of the
signal, not of the model: the information needed to separate them is not in
the audio. That's why the class is `impacte` and the alert reads "possible
incident", not "fall detected". Thunder has the same problem; the light
sensor already on the board could help rule it out.

**Plosives look like small impacts.** The /p/, /t/ and /k/ sounds in speech
are broadband bursts with a sharp attack, and they are the main source of
false alarms while someone is talking in the room.

**Precision is the weak point.** Roughly 30% of `normal` windows are
classified as some alert class. The decision logic in §9 is what makes the
system usable in spite of this.

**No clip in the dataset comes from a real care home.** The system is
trained on generic public audio and validated in a private room. A real
deployment would need recordings from the actual environment, with the
consent that implies.

---

## License

MIT — see [`LICENSE`](LICENSE).

The source datasets (AudioSet, FSD50K, COUGHVID, ESC-50) keep their own
licenses; check them before redistributing `dataset_final_16khz/`.
