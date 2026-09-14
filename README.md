# AI Night Guardian

> Acoustic detection of night-time incidents in care homes, running locally
> on-device and **without recording or storing any audio**.

Submitted to **HackEstiu 2026** (Universitat Politècnica de Catalunya).

- **Team:** Jan Díaz Carreras-Candi · Guillem Guilera Aulet · Joan Montobbio Palmer
- **Affiliation:** ETSETB — Universitat Politècnica de Catalunya (UPC), Barcelona
- **Hardware:** Arduino UNO Q + Modulino (temperature / light) + USB-C lavalier microphone + 3D printed enclosure
- **License:** MIT — see [`LICENSE`](LICENSE)
- **Edge Impulse™ project (public):** see [`Edge Impulse`](https://studio.edgeimpulse.com/public/1106722/live)
- **Demo video:** see [`Video`](https://youtu.be/zw-_enrB-u0)

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

**Additional:**

In the app you can find the temperature and light information of each room via the two Modulino sensors.

Because it is a **low-cost system with local processing**, it can be
deployed in care homes, assisted-living facilities and even in the homes of
older people living alone.

## License

MIT — see [`LICENSE`](LICENSE).

The source datasets (AudioSet, FSD50K, COUGHVID, ESC-50) keep their own
licenses; check them before redistributing `dataset_final_16khz/`.
