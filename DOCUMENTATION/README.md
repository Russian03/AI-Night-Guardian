# AI Night Guardian — Reproduction Guide

Complete guide to build the system from scratch: 3D-printed parts, Arduino UNO Q firmware and mobile app.

No prior knowledge of Arduino, Flutter or 3D printing is assumed. Follow the blocks in order: block 3 (firmware) only depends on block 2 if you want the enclosure assembled, but block 4 (app) requires the firmware to be running first.

---

## 0. Repository layout

```
APP/                        Mobile application (Flutter)
ARDUINO/
  ├── ai_night_guardian_firmware.tar.gz        Full Arduino App Lab application
  └── 3D_DESIGNS/                              Enclosure models (.obj / .stl)
```

Inside the `.tar.gz`, the App Lab application has this shape:

```
ai_night_guardian_firmware/
  ├── app.yaml              App Lab application definition
  ├── python/
  │    ├── main.py          Entry point: launches the three processes
  │    └── device_identity.py   Identity + QR generator
  ├── ai_night_guardian/
  │    ├── bleperipheral.py     BLE provisioning
  │    ├── mqtt_publisher.py    Heartbeat, sensors and configuration
  │    ├── audio_publisher.py   Audio inference and event publishing
  │    └── *.eim                Edge Impulse model
  ├── sketch/sketch.ino     Microcontroller code (Modulino sensors)
  └── requirements.txt      Python dependencies
```

---

## 1. What you need

**Hardware**

| Item | Notes |
|---|---|
| Arduino UNO Q (4 GB) + USB-C power	| The MPU side is what runs Linux and the model | 
| USB-C microphone	| Audio input for the classifier | 
| USB-C hub	| The board has a single USB-C port, so the hub is what lets you power it and plug the microphone in at the same time | 
| Modulino temperature and light sensors	| Daisy-chained over Qwiic/I2C | 
| USB-C cable to PC	| For the initial setup | 
| Android phone	| For the app | 

**Software on the PC**

| Program | Purpose |
|---|---|
| [Arduino App Lab](https://www.arduino.cc/en/software) | Load and run the firmware |
| [Ultimaker Cura](https://ultimaker.com/software/ultimaker-cura/) | Prepare the 3D parts |
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | Build the app |
| [Git](https://git-scm.com/) | **Required**: the Flutter SDK uses it internally, and without it no `flutter` or `dart` command works |
| Android Studio (or just the command-line tools + SDK) | Build for Android |

---

## 2. 3D-printed parts

The files live in `ARDUINO/3D_DESIGNS/`. An `.stl` or `.obj` is geometry only: it describes the shape but knows nothing about your printer. You need a **slicer** to turn that shape into the movement instructions the machine understands (a `.gcode` file).

### 2.1 Preparing the file in Cura

1. Install Ultimaker Cura and open it.
2. On first launch it asks you to **add a printer**. Pick your exact model from the list. If it isn't there, use *Add a non-networked printer → Custom* and enter the build volume and nozzle diameter (usually 0.4 mm). This step is what makes the resulting `.gcode` valid for your machine.
3. `File → Open File(s)` and select the `.stl` (or the `.obj`; Cura accepts both, `.stl` being the standard for printing).
4. The part appears on the virtual bed. Check:
   - **Orientation**: use *Rotate* to lay the largest flat face on the bed. It reduces supports and improves adhesion.
   - **Size**: with *Scale*, verify the dimensions are what you expect. If the model imports 1000× too small, that's a unit problem in the `.obj` — use the `.stl` instead.

### 2.2 Recommended settings

| Setting | Value | Reason |
|---|---|---|
| Material | PLA | Enough for indoor use, easiest to print |
| Layer height | 0.2 mm | Balance between quality and time |
| Infill | 15–20 % | The enclosure carries no load |
| Walls | 2–3 | Sufficient rigidity |
| Supports | Only for overhangs >45° | Cura highlights them in red once *Support* is enabled |
| Bed adhesion | *Brim* | Stops corners from lifting |

### 2.3 Printing

1. Click **Slice** (bottom right). Cura computes the toolpath and shows estimated time and material.
2. Check the *Preview* view to make sure no layers are printing into thin air.
3. **Save to Disk** or **Save to Removable Drive**: writes the `.gcode` to the printer's SD card or USB stick.
4. Insert the media into the printer, pick the file on its screen and start the print.

Print every part in the directory before assembling. The microphone must line up with the grille in the enclosure: do not cover it with material, inference depends directly on the acoustic signal.

---

## 3. Arduino UNO Q firmware

### 3.1 First contact with the board

1. Install **Arduino App Lab** on the PC and open it.
2. Connect the UNO Q to the PC with the USB-C cable and wait for App Lab to detect it.
3. Enter the **board's WiFi credentials** when prompted. This is the network the device publishes from over MQTT; it must be the same network (or one with Internet access) that the phone uses.
4. If App Lab offers a board system update, install it and reboot. Do this now, not after loading the application.

### 3.2 Loading the application

App Lab imports packaged applications. Extract the tar first if your version only accepts a folder or a `.zip`:

```bash
tar -xzf ai_night_guardian_firmware.tar.gz
```

In the interface:

1. Go to **My Apps**.
2. Click **Create New App → Import App**.
3. Select the **whole** package (the `.tar.gz` or the complete `ai_night_guardian_firmware` folder, not individual files). The app bundles the Python code, the microcontroller sketch and `app.yaml`; if you import loose pieces, App Lab won't recognise it as an application.
4. The application shows up as a card under **My Apps**.

Terminal equivalent (from inside the UNO Q):

```bash
arduino-app-cli app import ai_night_guardian_firmware.tar.gz
```

### 3.3 Placing the AI model

The `.eim` file is the compiled model and may not be in the repository because of its size. If it's missing:

1. In Edge Impulse Studio, open the project → **Deployment**.
2. Choose **Linux (AARCH64)** and hit *Build*. You get an `.eim` file.
3. Copy it into the application's `ai_night_guardian/` folder over SCP:

   ```bash
   scp model.eim arduino@<UNO_Q_IP>:/home/arduino/ArduinoApps/ai_night_guardian_firmware/ai_night_guardian/
   ```

4. Make it executable (it's a binary, not a data file):

   ```bash
   ssh arduino@<UNO_Q_IP> "chmod +x /home/arduino/ArduinoApps/ai_night_guardian_firmware/ai_night_guardian/*.eim"
   ```

5. Open `audio_publisher.py` and check that the `EIM_PATH` constant holds **exactly** your file name. If it doesn't match, the script falls into its retry loop and never classifies anything.

### 3.4 Setting the microphone

`audio_publisher.py` has `AUDIO_DEVICE_ID = 8`. That number identifies the microphone on *that* board and changes with the hardware and the order things were plugged in. To find yours, in the UNO Q terminal:

```bash
python3 -m sounddevice
```

Find your microphone in the list (or the `default` entry) and put its index in `AUDIO_DEVICE_ID`.

### 3.5 Running it

1. With the application open in App Lab, press **Run**. The first run installs the dependencies from `requirements.txt` and takes several minutes.
2. Open the App Lab **Console**. You should see, in this order:

   ```
   [AI Night Guardian] device_id: AING-XXXXXX
   BLE peripheral launched
   MQTT publisher launched
   Audio publisher launched (nice 10)
   [MQTT audio] Conectado al broker, codigo: Success
   [AI Night Guardian] Modelo cargado. Clases: [...]
   [ESCUCHA] Micrófono e inferencia ACTIVOS
   ```

   If it keeps repeating *Audio no disponible todavía*, go back to 3.3 and 3.4.
3. This first run creates `device_identity.json` and `provisioning_qr.png` inside the application folder. **Download that PNG** — it's the QR the app scans to pair:

   ```bash
   scp arduino@<UNO_Q_IP>:/home/arduino/ArduinoApps/ai_night_guardian_firmware/python/provisioning_qr.png .
   ```

   Print it and stick it on the enclosure. Never publish it anywhere: it contains the device's pairing key.

### 3.6 Run at startup

A monitoring device has to come back on its own after a power cut, without anyone opening App Lab.

1. In the top right corner, next to the **Run** button, click the **arrow (▼)** to open the menu.
2. Turn on the **Run at startup** toggle.
3. A **DEFAULT** badge appears next to the application name, confirming it will start on boot.

Terminal equivalent:

```bash
arduino-app-cli properties set default user:ai_night_guardian_firmware
```

Test it for real: unplug power, plug it back in, wait a minute and check that the device reappears in the app.

---

## 4. Mobile application

The code is in `APP/`. It's built with Flutter and validated on Android.

### 4.1 Setting up the environment

1. Install **Git** and confirm it responds from a fresh terminal:

   ```bash
   git --version
   ```

   Without it, Flutter commands fail with errors about `update_engine_version`.
2. Install the **Flutter SDK** and add it to your PATH.
3. Run the diagnostic and fix everything it flags in red:

   ```bash
   flutter doctor
   ```

   For Android you need the SDK installed and the licences accepted (`flutter doctor --android-licenses`).

### 4.2 Build and install

```bash
cd APP
flutter pub get
```

With the phone connected over USB and **USB debugging** enabled in developer options:

```bash
flutter devices     # confirm your phone shows up
flutter run
```

To produce an APK you can install without a cable:

```bash
flutter build apk --release
```

The file lands in `build/app/outputs/flutter-apk/app-release.apk`. Copy it to the phone and install it, accepting the unknown-sources warning.

### 4.3 Phone permissions

Grant these when the app asks, or under *Settings → Apps → AI Night Guardian → Permissions*:

- **Camera**: scanning the device QR.
- **Bluetooth / Nearby devices**: BLE provisioning.
- **Location**: Android requires it for BLE scanning even though position is never used.
- **Notifications**: without this you won't see alerts.

The phone and the UNO Q must be on the **same WiFi network**.

---

## 5. Pairing device and app

With the firmware running (block 3) and the app installed (block 4):

1. Open the app → **Add device**.
2. **Scan the QR** stuck on the enclosure. The app reads the `device_id` and the pairing key.
3. The app looks for the device over **Bluetooth**. Keep the phone within a metre.
4. Enter the facility's **WiFi SSID and password** and confirm the **room name**.
5. Wait for confirmation. The process has a countdown of up to 90 seconds: it needs both the BLE reply **and** the first MQTT heartbeat. Don't leave the screen early.
6. The device appears in the list with a green indicator.

### Final check

1. Open the device detail view and confirm temperature and light are updating (they should refresh every few seconds).
2. Make sure the **acoustic listening** toggle is on. If it's off, the microphone is never even opened and nothing will be detected.
3. Trigger an event: clap loudly near the microphone. The UNO Q console shows the classification and, if it clears the threshold, `[EVENTO enviado]`; the notification should reach the phone within seconds.

Coughing won't fire on a single burst: the system requires several distinct coughs within a time window to tell a real coughing fit from throat-clearing. To test it, cough repeatedly for about half a minute.

---

## 6. Troubleshooting

| Symptom | Most likely cause | Fix |
|---|---|---|
| `Audio no disponible todavia` looping | `.eim` missing, not executable, or wrong `AUDIO_DEVICE_ID` | Review 3.3 and 3.4 |
| Many alerts from an empty room | Silence threshold (`SILENCE_RMS`) below the real background noise | Set `DEBUG_RMS = True` for a minute, read the idle values and raise the threshold |
| Temperature and light arrive as `null` | Inference is hogging the CPU | Confirm `main.py` launches the audio process with `nice -n 10` |
| Device shows as offline | The UNO Q lost WiFi or the process stopped | Check the App Lab console; confirm **Run at startup** is enabled |
| App can't find the device over BLE | Bluetooth or location permission off; provisioning window closed | Enable both and reboot the device to reopen the BLE window |
| No `flutter` or `dart` command works | Git isn't on the PATH | Install Git and open a new terminal |
| Icon or text doesn't update after rebuilding | Android cache | Uninstall the app from the phone, reboot it, then reinstall |

---

## 7. Privacy note

Audio is never stored or transmitted: it's processed in memory in one-second windows and discarded immediately after inference. The only thing leaving the device is text metadata (room, time, incident type). Any firmware change must preserve this property — it's the basis for the system qualifying legally as an automated emergency sensor rather than a listening microphone.

The default MQTT broker is public (`broker.hivemq.com`), which is fine for a demo. Before any real deployment it must be replaced by your own broker with TLS and per-device credentials.
