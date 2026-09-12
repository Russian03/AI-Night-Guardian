# AI Night Guardian

> Detecció acústica d'incidències nocturnes en residències de gent gran, amb inferència local i **sense gravar ni emmagatzemar cap àudio**.

Projecte presentat i acceptat a **HackEstiu 2026** (UPC).

- **Equip:** Jan Díaz Carreras-Candi · Guillem Guilera Aulet · Joan Montobbio Palmer
- **Hardware:** Arduino Uno Q + Modulino (temperatura / llum) + mòdul micròfon I2S
- **Llicència:** open-source — _pendent d'escollir i afegir el fitxer `LICENSE`_
- **Documentació a Arduino Project Hub:** _pendent de publicar — [afegir enllaç aquí]_
- **Model d'Edge Impulse (públic):** _pendent de publicar — [afegir enllaç aquí]_

---

## Índex

1. [El repte](#1-el-repte)
2. [La solució](#2-la-solució)
3. [Privacitat des del disseny](#3-privacitat-des-del-disseny)
4. [Arquitectura](#4-arquitectura)
5. [Hardware](#5-hardware)
6. [Estructura del repositori](#6-estructura-del-repositori)
7. [El dataset](#7-el-dataset)
8. [El model d'IA (Edge Impulse)](#8-el-model-dia-edge-impulse)
9. [Posar-lo en marxa](#9-posar-lo-en-marxa)
10. [Protocols de comunicació](#10-protocols-de-comunicació)
11. [Estat actual del projecte](#11-estat-actual-del-projecte)
12. [Requisits d'entrega HackEstiu 2026](#12-requisits-dentrega-hackestiu-2026)

---

## 1. El repte

En residències de gent gran, durant el torn de nit, el personal ha de fer rondes periòdiques per totes les habitacions per comprovar que els residents estiguin bé. Aquestes visites són necessàries per detectar incidències —caigudes, episodis de tos persistent, crits d'auxili o plors—, però tenen dos problemes:

- **Interrompen el son** dels residents cada vegada que s'obre una porta.
- **No garanteixen la detecció** en el moment en què la incidència passa: entre ronda i ronda pot passar mitja hora o més.

El repte que ens proposem, de cara a la democratització de la intel·ligència artificial, és resoldre aquesta ineficiència amb un model **accessible per a qualsevol residència o centre sociosanitari**, que identifiqui incidències durant el torn de nit **sense comprometre la privadesa** dels residents i que notifiqui el personal a l'instant.

## 2. La solució

**AI Night Guardian** és un dispositiu basat en Arduino Uno Q que executa un model d'intel·ligència artificial **localment** per classificar sons rellevants dins d'una habitació.

El sistema distingeix esdeveniments com:

| Esdeveniment | Per què importa |
|---|---|
| Roncs | Possibles apnees o dificultat respiratòria |
| Tos persistent | Infecció respiratòria, ennuegament |
| Cops / caigudes | Emergència immediata (patró acústic d'impacte) |
| Crits demanant ajuda | Emergència immediata |
| Plors | Malestar, dolor, desorientació |
| Silenci prolongat després d'un soroll inesperat | Possible pèrdua de consciència després d'una caiguda |

Quan detecta un esdeveniment d'interès, **registra l'hora i el tipus d'incidència** i envia una notificació a l'aplicació mòbil del personal. Així els cuidadors poden prioritzar les habitacions que realment requereixen atenció immediata, reduint el temps de resposta.

**Alertes addicionals** (no acústiques):

- **Canvi d'il·luminació** de l'ambient (encesa/apagada de llums) via sensor Modulino de llum.
- **Temperatura fora d'un interval configurable** (p. ex. `[20 °C, 30 °C]`), especialment rellevant durant onades de calor.

Com que és un sistema de **baix cost amb processament local**, es pot desplegar fàcilment en residències, centres sociosanitaris i fins i tot domicilis de persones grans que viuen soles. També admet variacions del cas d'ús, com per exemple la detecció de plors de nens petits.

## 3. Privacitat des del disseny

Aquest és el punt central del projecte i el motiu pel qual és desplegable legalment en una residència sota el RGPD.

- **No hi ha cap tractament ni emmagatzematge de dades personals o biomètriques.**
- El senyal acústic de l'habitació es capta **en streaming directament a la memòria del microcontrolador**.
- Un cop la xarxa neuronal executa la inferència local, **la finestra d'àudio s'esborra de manera immediata i irreversible**, sense haver estat mai enregistrada.
- El dispositiu **no retransmet àudio** a l'exterior ni a cap entitat externa a la residència.
- L'únic que surt del dispositiu són **metadades de text** del tipus:

  ```
  Habitació 14 — 02:40 — Cop detectat
  ```

Per tant, el sistema actua legalment com un **sensor d'emergències automatitzat**, i no com un micròfon d'escolta.

L'app inclou a més un **interruptor de "mode escucha"** per habitació, que permet aturar la inferència en qualsevol moment des del mòbil del personal (topic MQTT `config`, veure §10).

## 4. Arquitectura

```
┌─────────────────────────────── HABITACIÓ ───────────────────────────────┐
│                                                                         │
│   Micròfon I2S ──► Arduino Uno Q                                        │
│                    ├── sketch.ino  (Zephyr / MCU)                       │
│                    │    · captura àudio I2S 16 kHz                      │
│                    │    · llegeix Modulino: temperatura, humitat, llum   │
│                    │    · exposa read_sensors() via RouterBridge        │
│                    │                                                     │
│                    └── Python (Linux del Uno Q)                         │
│                         · device_identity.py → device_id + QR            │
│                         · ble_peripheral.py  → provisioning WiFi per BLE │
│                         · mqtt_publisher.py  → heartbeat cada 15 s       │
│                         · config_listener.py → rep ordres de l'app       │
│                         · [pendent] inferència Edge Impulse             │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │  MQTT / TCP 1883
                                   │  broker.hivemq.com
                                   │  residencia/<device_id>/{heartbeat,eventos,config}
                                   ▼
                        ┌────────────────────────┐
                        │  App mòbil (Flutter)   │
                        │  · onboarding QR + BLE │
                        │  · dashboard per sala  │
                        │  · notificacions push  │
                        └────────────────────────┘
```

**Flux d'una incidència:** micròfon I2S → finestra d'1–2 s a RAM → finestratge + FFT → filtres Mel / MFCC → **esborrat de la finestra d'àudio** → inferència → si hi ha anomalia, publicació d'un JSON de text a MQTT → notificació local al mòbil del personal.

## 5. Hardware

| Component | Notes |
|---|---|
| **Arduino Uno Q** (4 GB) + cable d'alimentació | Placa principal; executa Linux + MCU Zephyr |
| **Sensors Modulino** | Temperatura (`ModulinoThermo`) i llum (`ModulinoLight`) |
| **Mòdul micròfon I2S** (p. ex. INMP441) | Capta els sons que es passen a la IA |
| **Mòdul RTC** (p. ex. DS3231) *(opcional)* | Hora precisa. Alternativa: servidor NTP via WiFi |

## 6. Estructura del repositori

```
AI-Night-Guardian/
├── ai_night_guardian_firmware/        # Tot el que corre al dispositiu
│   ├── sketch/
│   │   ├── sketch.ino                 # MCU: I2S + Modulino + RouterBridge
│   │   ├── sketch.yaml                # Perfil de compilació (arduino:zephyr)
│   │   └── libraries/                 # Llibreries Arduino incloses
│   ├── ai_night_guardian/             # Capa Python (Linux del Uno Q)
│   │   ├── main.py                    # Entrypoint: identitat + QR
│   │   ├── device_identity.py         # device_id, provisioning_key, QR
│   │   ├── ble_peripheral.py          # GATT per provisionar WiFi des de l'app
│   │   ├── mqtt_publisher.py          # Heartbeat amb sensors cada 15 s
│   │   ├── config_listener.py         # Rep {"listening": bool} de l'app
│   │   └── event_simulator.py         # Publica incidències simulades (demo)
│   ├── python/                        # Variant llançada per l'Arduino App CLI
│   └── app.yaml
│
├── ai_guardians/                      # App mòbil Flutter (Android/iOS/desktop)
│   └── lib/
│       ├── main.dart
│       ├── data/                      # mqtt_service, notification_service, device_store
│       ├── domain/                    # SavedDevice, DeviceCredentials
│       ├── presentation/screens/      # splash, home, devices, QR, BLE, WiFi, dashboard, settings
│       └── theme/
│
├── dataset_final_16khz/               # 30.487 mostres .wav a 16 kHz mono
├── DATASET INFO.pdf                   # Metodologia d'obtenció i preprocessat
├── Hackestiu_2026_Project_Proposal.pdf
└── README.md
```

## 7. El dataset

`dataset_final_16khz/` conté **30.487 mostres** `.wav` (~7,2 GB), totes normalitzades a **16 kHz mono**. Els noms dels fitxers segueixen el patró `<classe>_<font>_<id>.wav`.

### Fonts

| Dataset | Mostres | Llicència / origen |
|---|---:|---|
| [AudioSet](https://research.google.com/audioset/) (Google) | 10.463 | Clips de 10 s extrets de YouTube (5.465 *train* + 4.998 *eval*) |
| [FSD50K](https://zenodo.org/records/4060432) (UPF) | 13.642 | Zenodo (9.692 *dev* + 3.950 *eval*) |
| [COUGHVID](https://zenodo.org/records/4048312) | 5.902 | Zenodo — tos certificada |
| [ESC-50](https://github.com/karolpiczak/ESC-50) | 480 | GitHub — mostres netes de 5 s |
| **Total** | **30.487** | |

### Metodologia d'extracció

Documentada al detall a **[`DATASET INFO.pdf`](DATASET%20INFO.pdf)**. Resum:

- **AudioSet** no conté àudio: cal creuar `balanced_train_segments.csv` / `eval_segments.csv` amb els IDs de l'[ontologia](https://github.com/audioset/ontology) i descarregar els fragments amb `yt-dlp` + `FFmpeg`, retallant per marques de temps sense baixar el vídeo sencer. Alguns vídeos ja no estan disponibles.
- **ESC-50** es filtra pel camp `target` de `esc50.csv` (p. ex. `24` = *Coughing*, `20` = *Crying baby*, `28` = *Snoring*).
- **FSD50K** requereix creuar els noms numèrics dels `.wav` amb `FSD50K.ground_truth` per aïllar les classes d'interès.
- **COUGHVID** es filtra estrictament per `cough_detected >= 0.95`, amb `quality_*` ∈ {ok, good} o buit i `severity_*` ∈ {severe} o buit.

### Per què 16 kHz mono

- **16 kHz** és l'estàndard de TinyML. Pel teorema de Nyquist permet registrar fins a 8 kHz, i la veu humana, els roncs i els cops concentren pràcticament tota la seva informació acústica per sota dels 4 kHz. Usar 44,1 kHz només afegiria freqüències agudes inútils i triplicaria el pes del fitxer, col·lapsant la RAM durant la generació de l'espectrograma.
- **Mono** perquè el model no necessita saber de quin costat prové el so, només si ha passat i com: divideix el processament matemàtic per dos.
- Els extractors d'AudioSet i COUGHVID ja forcen `-ar 16000 -ac 1` amb FFmpeg. ESC-50 i FSD50K copien el `.wav` original, així que tot el conjunt es passa per un script unificador que reescriu la capçalera WAV. Com que els `.wav` són PCM sense compressió, recodificar a 16 kHz mono és **transparent** (no degrada el so) i **neteja metadades residuals** que sovint provoquen errors de lectura al pujar a Edge Impulse.

### Data augmentation

Per evitar *overfitting* i falses alarmes, el dataset s'amplia amb ([`audiomentations`](https://github.com/iver56/audiomentations) / [`librosa`](https://librosa.org/)):

1. **Injecció de soroll de fons** — ventilació, soroll de carrer, estàtica. Que el model no es perdi si el resident tus amb l'aire condicionat encès.
2. **Pitch shifting** — un crit d'auxili d'un home amb veu greu sona molt diferent del d'una dona amb veu aguda.
3. **Guany aleatori** — un cop a mig metre del micròfon no sona igual que un al bany del fons de l'habitació.
4. **Time stretching** — una tos persistent pot ser ràpida i entretallada o lenta i espaiada.
5. **SpecAugment** — emmascarar blocs de temps/freqüència de l'espectrograma per forçar el model a decidir amb pistes incompletes.

## 8. El model d'IA (Edge Impulse)

Alimentar la xarxa amb àudio cru és inviable en un microcontrolador, així que s'extreuen **features**. Les dues vies, totes dues basades en l'**escala Mel** (que imita com l'oïda humana percep les freqüències):

- **Espectrogrames Mel** — imatge 2D (temps × freqüència, color = intensitat). Ideal per a **impactes secs**: cops i caigudes.
- **MFCC** (13–40 coeficients) — versió molt més comprimida via Transformada Discreta del Cosinus. És l'estàndard d'or per a esdeveniments **vocals**: roncs, crits, plors, tos.

### Pipeline en temps real dins del dispositiu

1. **Captura** — el mòdul I2S grava una finestra d'1–2 s.
2. **Finestratge** — es divideix en fragments de pocs mil·lisegons.
3. **FFT** — es calculen les freqüències presents.
4. **Filtres Mel & MFCC** — es generen els coeficients.
5. **Esborrat + inferència** — la finestra d'àudio s'esborra immediata i irreversiblement; **només els coeficients** passen pel model.
6. **Notificació** — si hi ha anomalia, es registra en text (`"Habitació 12 — 03:17 — Cop detectat"`) i s'envia a l'app.

Edge Impulse aporta els blocs DSP natius (Mel i MFCC), la gestió visual i etiquetatge del dataset, el data augmentation, i el desplegament directe com a **llibreria d'Arduino (.zip)** llesta per compilar al Uno Q.

> ⚠️ **Requisit d'entrega:** el model entrenat a Edge Impulse ha de ser **públic, obert i accessible per a tothom**. Enllaç del projecte públic: _pendent d'afegir_.

## 9. Posar-lo en marxa

### 9.1 Firmware (Arduino Uno Q)

**Requisits:** Arduino CLI amb la plataforma `arduino:zephyr`, Python 3.11+ al Linux de la placa, `nmcli` (NetworkManager) i BlueZ.

```bash
# Dependències Python
pip install qrcode[pil] paho-mqtt bluezero

# 1) Compilar i pujar el sketch a la MCU (I2S + Modulino + Bridge)
cd ai_night_guardian_firmware/sketch
arduino-cli compile --profile default . && arduino-cli upload -p <PORT> --profile default .

# 2) Generar identitat del dispositiu i el QR d'aprovisionament
cd ../ai_night_guardian
python3 main.py               # crea device_identity.json + provisioning_qr.png

# 3) Provisionament WiFi per BLE (l'app s'hi connecta i li passa SSID/password)
sudo python3 ble_peripheral.py

# 4) Publicar heartbeats amb les dades dels sensors
python3 mqtt_publisher.py

# 5) Escoltar ordres de configuració de l'app (mode escucha on/off)
python3 config_listener.py
```

Per provar l'app sense el model d'IA, es poden injectar incidències a mà:

```bash
python3 event_simulator.py caida     # o: tos, cop, crit, plor...
```

### 9.2 App mòbil

**Requisits:** Flutter SDK ≥ 3.13.2.

```bash
cd ai_guardians
flutter pub get
flutter run                   # o: flutter build apk --release
```

**Flux d'onboarding:** splash → *Afegir dispositiu* → escaneig del **QR** imprès/mostrat pel dispositiu (`device_id` + `provisioning_key`) → **escaneig BLE** → formulari de **WiFi + nom d'habitació** → el dispositiu es connecta i publica el seu primer heartbeat → **dashboard** amb temperatura, lux, uptime, última incidència i interruptor de mode escucha.

Permisos necessaris: Bluetooth, càmera (QR), ubicació (requerida per l'escaneig BLE a Android) i notificacions.

## 10. Protocols de comunicació

### MQTT

Broker públic de proves: `broker.hivemq.com:1883`. Tots els missatges són JSON amb `v`, `type`, `device_id`, `ts` i `payload`.

| Topic | Direcció | Contingut |
|---|---|---|
| `residencia/<device_id>/heartbeat` | dispositiu → app | Estat viu cada 15 s |
| `residencia/<device_id>/eventos` | dispositiu → app | Incidència detectada (QoS 1) |
| `residencia/<device_id>/config` | app → dispositiu | Configuració (QoS 1) |

**Heartbeat:**

```json
{
  "v": 1, "type": "heartbeat", "device_id": "AING-9D67B1",
  "ts": "2026-09-12T02:40:11+0200",
  "payload": {
    "room": "Habitació 14", "fw_version": "0.1.0", "uptime_s": 3720,
    "rssi": -55, "temp_c": 22.4, "lux": 3, "listening": true
  }
}
```

**Esdeveniment:**

```json
{
  "v": 1, "type": "event", "device_id": "AING-9D67B1",
  "ts": "2026-09-12T02:40:11+0200",
  "payload": {
    "room": "Habitació 14", "event_type": "caida",
    "confidence": 0.92, "detected_at": "2026-09-12T02:40:11+0200"
  }
}
```

**Configuració:**

```json
{ "type": "config", "payload": { "listening": false } }
```

### BLE (aprovisionament)

Servei tipus Nordic UART: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`

| Característica | UUID | Ús |
|---|---|---|
| TX (write) | `…0002-…` | L'app envia `{"type":"wifi_provision","ssid":…,"password":…,"room_name":…}` |
| RX (notify) | `…0003-…` | Reservat |
| STATUS (read/notify) | `…0004-…` | `{"type":"wifi_status","state":"connecting\|connected\|failed","ip":…}` |

### QR d'aprovisionament

```json
{ "device_id": "AING-XXXXXX", "provisioning_key": "…", "model": "UnoQ-v1", "fw_min_version": "0.1.0" }
```

## 11. Estat actual del projecte

### Funcionant

- [x] App Flutter completa: onboarding QR + BLE, provisionament WiFi, llista de dispositius, dashboard en viu, notificacions locals, mode escucha.
- [x] Provisionament WiFi per BLE des del mòbil (`nmcli`).
- [x] Identitat de dispositiu persistent + generació del QR.
- [x] Telemetria MQTT: heartbeat cada 15 s amb temperatura i lux reals via `RouterBridge`.
- [x] Canal de configuració bidireccional (mode escucha des de l'app).
- [x] Dataset de 30.487 mostres unificat a 16 kHz mono.
- [x] Simulador d'esdeveniments per validar el camí complet dispositiu → app.

### Pendent

- [ ] **Captura d'àudio al sketch.** `sketch.ino` inicialitza l'I2S a 16 kHz i llegeix mostres, però: (a) usa l'API Arduino `I2S` sense incloure `<I2S.h>` (només `<zephyr/drivers/i2s.h>`), i (b) llegeix **una sola mostra cada 2 s** dins del `loop()`, cosa insuficient per classificar. Cal passar a lectura per blocs continus en finestres d'1–2 s.
- [ ] **Inferència Edge Impulse al dispositiu** i publicació d'esdeveniments reals (ara els publica `event_simulator.py`). El punt d'enganxada és `save_listening_state()` a `config_listener.py`.
- [ ] **Pujar els scripts d'extracció del dataset** (`audioset_extractor.py`, `esc50_extractor.py`, `fsd50k_extractor.py`, `coughvid_extractor.py` i l'unificador FFmpeg) descrits a `DATASET INFO.pdf`: encara no són al repositori.
- [ ] **Publicar el projecte d'Edge Impulse** com a públic i enllaçar-lo.
- [ ] **Documentar a projecthub.arduino.cc** i enllaçar-ho.
- [ ] Alertes de temperatura fora d'interval configurable i de canvi d'il·luminació.
- [ ] RTC DS3231 (o NTP) per a hores precises sense dependre de la xarxa.
- [ ] Broker MQTT propi amb TLS i autenticació: `broker.hivemq.com` és públic i només serveix per a prototipatge.

## 12. Requisits d'entrega HackEstiu 2026

| Requisit | Estat |
|---|---|
| Projecte open-source, tot penjat i documentat a GitHub | ⚠️ Codi penjat i documentat en aquest README; falta el fitxer `LICENSE` i els scripts d'extracció del dataset |
| Documentat a [projecthub.arduino.cc](https://projecthub.arduino.cc) | ❌ Pendent |
| Model d'Edge Impulse públic, obert i accessible | ❌ Pendent |

---

## Llicència

Aquest projecte és **open-source**, tal com exigeixen les bases d'HackEstiu 2026. Encara cal
escollir la llicència (MIT i Apache-2.0 són les opcions habituals per a projectes de hackató) i
afegir el fitxer `LICENSE` a l'arrel del repositori.

Els datasets d'origen (AudioSet, FSD50K, COUGHVID, ESC-50) conserven les seves llicències respectives; consulteu-les abans de redistribuir `dataset_final_16khz/`.
