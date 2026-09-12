# 🤖 Sensor Data Simulator

Registry-driven server-room telemetry generator. It reads the seeded `devices`
registry (issue #70) from MongoDB and, on every tick, writes one correlated
reading per device/channel straight into the `sensor_readings` collection.

## 📋 What it does

- **Registry-driven**: emits one reading for every seeded device/channel per
  tick, using the channel's declared `unit` from the registry (never a
  hard-coded unit table).
- **Correlated, time-aware signals** (a lightweight model, not a physics engine):
  - diurnal ambient curve drives rack `intake_temp`;
  - a slow synthetic rack `load` drives `power_draw` and, with intake,
    `exhaust_temp`; `fan_rpm` rises with `exhaust_temp`;
  - `pdu` `power_draw` follows aggregate rack power, `current` is derived from
    power / line voltage;
  - `ups` `load_pct` follows aggregate rack power; `crac` `return_temp` follows
    the mean rack exhaust;
  - bounded Gaussian noise on every continuous channel;
  - `door_contact` is mostly `"closed"` with rare, seed-deterministic opens.
- **Anomaly injection** (env-gated, off by default): a small
  `NORMAL → ACTIVE → RECOVERY → NORMAL` state machine, at most one anomaly at a
  time. Scenarios cycle round-robin:
  - `breach_high` — one device/channel is pushed well past a breach value for a
    bounded window, then recovers;
  - `mains_loss` — `ups` `input_voltage` sags and `battery_pct` discharges during
    the window, then `input_voltage` returns to nominal and `battery_pct`
    recharges.
- **Deterministic**: signal noise and anomaly selection come from a seeded RNG
  (`SEED`, default `42`). A run with the same `SEED`, configuration, simulation
  start instant, and device set repeats exactly, including values, timestamps,
  and device/channel ordering. Devices are ordered by `deviceId`; channel order
  remains as declared in the registry. Generated timestamps are
  `start + tick * interval`.
- **Paced runtime**: the first tick runs immediately and subsequent ticks are
  paced from the process runtime clock, independently of the simulation start
  instant. A blocking write that misses a deadline re-anchors the next tick to
  one full interval after the current runtime time, avoiding catch-up bursts.

## 🚀 Running

### Locally (with Maven)

```bash
mvn clean package
java -jar target/sensor-data-simulator-1.0.0.jar
```

The `devices` registry must already be seeded (run the stack's `mongo-seed`
step, or `docker compose up -d mongo-seed`).

### With Docker Compose

Already wired in the root `docker-compose.yml`:

```bash
docker compose up -d sensor-simulator
```

## ⚙️ Environment variables

| Variable                 | Default                                     | Description                                                                 |
| ------------------------ | ------------------------------------------- | -------------------------------------------------------------------------- |
| `MONGO_URI`              | `mongodb://localhost:27017/?replicaSet=rs0` | MongoDB connection string                                                 |
| `MONGO_DATABASE`         | `omnivise_iot`                              | Database name                                                             |
| `MONGO_COLLECTION`       | `sensor_readings`                           | Target collection                                                         |
| `INTERVAL_SECONDS`       | `5`                                         | Simulated seconds between ticks (must be `>= 1`)                          |
| `ANOMALY_MODE`           | `false`                                     | Enable anomaly injection                                                  |
| `ANOMALY_EVERY_TICKS`    | `60`                                        | Ticks between anomaly onsets (~5 min at the default interval)             |
| `ANOMALY_DURATION_TICKS` | `6`                                         | Length of the ACTIVE window (~30s at the default interval)               |
| `SEED`                   | `42`                                        | PRNG seed; unset/blank → `42`                                                                                   |
| `START_TIME`             | launch time                                 | Optional fixed ISO-8601 **simulation** start instant, e.g. `2026-09-10T00:00:00Z`; blank keeps launch-time behavior |

The config is validated at startup and the simulator refuses to run on an
invalid combination:

- `INTERVAL_SECONDS >= 1` (always);
- when `ANOMALY_MODE=true`: `ANOMALY_DURATION_TICKS >= 1`, and
  `ANOMALY_EVERY_TICKS > ANOMALY_DURATION_TICKS + recoveryTicks` where
  `recoveryTicks = max(2, ANOMALY_DURATION_TICKS / 2)`. Only then does the next
  onset land in a NORMAL phase, so the configured cadence actually holds (at most
   one anomaly is ever active). With `ANOMALY_MODE=false` the anomaly values are
   inert and not checked.
- when `START_TIME` is set, it must be an ISO-8601 instant; otherwise the
  simulation starts at process launch time. This setting affects generated
  timestamps and time-dependent signals only; it never delays process startup
  or controls runtime pacing.

## 📊 Reading shape

Post-cutover schema (issue #70), `timestamp` stored as a BSON `Date`:

```json
{
  "deviceId": "rack-a1",
  "channel": "exhaust_temp",
  "value": 31.8,
  "unit": "°C",
  "timestamp": { "$date": "2026-09-10T10:30:00Z" }
}
```

`door_contact` reports the string state `"closed"` / `"open"`; all other
channels report a number.

## 🛠️ Development

**Requirements**: Java 17+, Maven 3.8+, a running MongoDB 7 replica set with the
`devices` registry seeded.

```bash
mvn clean compile   # compile
mvn test            # unit tests (SimulatorEngine + registry parsing)
mvn clean package   # fat JAR
```

## 🔍 Verification

With **mongosh**:

```bash
docker exec -it omnivise-mongodb mongosh
use omnivise_iot
db.sensor_readings.find().sort({ timestamp: -1 }).limit(20)
```

Enable `ANOMALY_MODE=true` and watch a channel breach and then recover over a
bounded window.

---

**Made with ❤️ for OmniVise IoT**
