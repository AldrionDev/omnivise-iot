package com.omnivise.simulator;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.function.LongSupplier;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.mongodb.client.model.Sorts;
import com.omnivise.simulator.SimulatorEngine.Config;
import com.omnivise.simulator.SimulatorEngine.Device;
import com.omnivise.simulator.SimulatorEngine.Reading;

/**
 * I/O shell for the server-room simulator.
 *
 * <p>Reads the seeded {@code devices} registry (issue #70) once at startup, then
 * on every tick asks {@link SimulatorEngine} for the readings and writes them
 * straight into MongoDB in the post-cutover
 * {@code deviceId / channel / value / unit / timestamp} shape, with the
 * {@code timestamp} stored as a BSON {@code Date}.
 *
 * <p>All modelling lives in {@link SimulatorEngine}; this class only does env
 * parsing, Mongo I/O and the tick loop. The simulation epoch used for generated
 * readings is independent from the runtime epoch used for pacing.
 */
public class SensorDataSimulator {

    private static final Map<String, String> ENV = System.getenv();

    private static final String MONGO_URI = env("MONGO_URI", "mongodb://localhost:27017/?replicaSet=rs0");
    private static final String DATABASE_NAME = env("MONGO_DATABASE", "omnivise_iot");
    private static final String COLLECTION_NAME = env("MONGO_COLLECTION", "sensor_readings");

    /** Sleep seam so the tick loop can be tested without real waits. */
    @FunctionalInterface
    interface Sleeper {
        void sleep(long millis) throws InterruptedException;
    }

    public static void main(String[] args) {
        int intervalSeconds = envInt("INTERVAL_SECONDS", 5);
        boolean anomalyMode = envBool("ANOMALY_MODE", false);
        int anomalyEveryTicks = envInt("ANOMALY_EVERY_TICKS", 60);
        int anomalyDurationTicks = envInt("ANOMALY_DURATION_TICKS", 6);
        long seed = resolveSeed(ENV.get("SEED"));
        long startMillis;
        try {
            startMillis = resolveStartMillis(ENV.get("START_TIME"), System.currentTimeMillis());
        } catch (IllegalArgumentException e) {
            System.err.println("❌ Invalid configuration: " + e.getMessage());
            System.exit(1);
            return;
        }

        // Fail fast on an invalid configuration, before opening any connection or
        // starting the loop (issue #71 finding B4).
        Config config;
        try {
            config = new Config(intervalSeconds, seed, anomalyMode,
                    anomalyEveryTicks, anomalyDurationTicks,
                    List.of("breach_high", "mains_loss"), startMillis);
        } catch (IllegalArgumentException e) {
            System.err.println("❌ Invalid configuration: " + e.getMessage());
            System.exit(1);
            return; // unreachable; keeps `config` definitely assigned
        }

        System.out.println("🚀 Starting Sensor Data Simulator...");
        System.out.println("💾 Database: " + DATABASE_NAME);
        System.out.println("📋 Collection: " + COLLECTION_NAME);
        System.out.println("⏱️  Interval: " + intervalSeconds + "s");
        System.out.println("🎲 Seed: " + seed + " (override with SEED)");
        System.out.println("🕒 Start time: " + Instant.ofEpochMilli(startMillis)
                + (ENV.get("START_TIME") == null || ENV.get("START_TIME").isBlank()
                        ? " (wall clock)" : " (fixed by START_TIME)"));
        System.out.println("⚠️  Anomaly mode: " + anomalyMode
                + " (every " + anomalyEveryTicks + " ticks, for " + anomalyDurationTicks + " ticks)");
        System.out.println("-".repeat(60));

        try (MongoClient mongoClient = MongoClients.create(MONGO_URI)) {
            MongoDatabase database = mongoClient.getDatabase(DATABASE_NAME);
            MongoCollection<Document> readings = database.getCollection(COLLECTION_NAME);

            List<Device> registry = parseDevices(readAllDevices(database));
            if (registry.isEmpty()) {
                System.err.println("❌ 'devices' registry is empty — is the mongo-seed step complete?");
                System.exit(1);
            }
            int channelCount = registry.stream().mapToInt(d -> d.channels().size()).sum();
            System.out.println("✅ Registry loaded: " + registry.size() + " devices, "
                    + channelCount + " channels/tick");

            SimulatorEngine engine = new SimulatorEngine(registry, config);

            System.out.println("🤖 Generating readings...\n");
            runLoop(engine, batch -> writeBatch(readings, batch),
                    intervalSeconds, startMillis,
                    System::currentTimeMillis, SensorDataSimulator::sleepMillis,
                    Long.MAX_VALUE);
        } catch (Exception e) {
            System.err.println("❌ MongoDB connection error: " + e.getMessage());
            System.exit(1);
        }
    }

    /**
     * The tick loop. The first tick runs immediately. Subsequent ticks use an
     * absolute schedule anchored to the current runtime clock when this method
     * starts, never to the simulation epoch. If sinking a tick misses its next
     * deadline, the schedule is re-anchored one full interval after the current
     * runtime time instead of executing catch-up ticks. Single-threaded, plain
     * loop — no scheduler.
     *
     * @param engine          the deterministic signal model
     * @param sink            consumes one tick's readings (Mongo write in production)
     * @param intervalSeconds       simulated seconds per tick
     * @param simulationStartMillis simulation epoch; deliberately not used for pacing
     * @param clock                 current runtime-clock millis
     * @param sleeper         blocks for the requested millis
     * @param maxTicks        stop after this many ticks ({@link Long#MAX_VALUE} in production)
     */
    static void runLoop(SimulatorEngine engine,
            Consumer<List<Reading>> sink,
            int intervalSeconds,
            long simulationStartMillis,
            LongSupplier clock,
            Sleeper sleeper,
            long maxTicks) {
        if (intervalSeconds < 1) {
            throw new IllegalArgumentException("intervalSeconds must be >= 1");
        }
        long intervalMillis = intervalSeconds * 1000L;
        long nextTickDeadline = clock.getAsLong();
        for (long tick = 0; tick < maxTicks; tick++) {
            try {
                List<Reading> batch = engine.tick(tick);
                sink.accept(batch);
                engine.currentAnomaly().ifPresent(a -> System.out.printf(
                        "  ⚠️  anomaly %s [%s] %s/%s%n", a.scenario(), a.phase(), a.deviceId(), a.channel()));
                System.out.printf("[tick %d] ✅ inserted %d readings%n", tick, batch.size());

            } catch (Exception e) {
                System.err.println("❌ Error during tick: " + e.getMessage());
            } finally {
                long now = clock.getAsLong();
                long scheduledNextTick = nextTickDeadline + intervalMillis;
                long remaining;
                if (scheduledNextTick > now) {
                    remaining = scheduledNextTick - now;
                    nextTickDeadline = scheduledNextTick;
                } else {
                    // A blocking sink missed one or more deadlines. Start a new
                    // cadence from now so recovery cannot produce catch-up ticks.
                    nextTickDeadline = now + intervalMillis;
                    remaining = intervalMillis;
                }
                try {
                    sleeper.sleep(remaining);
                } catch (InterruptedException e) {
                    System.err.println("⚠️ Simulation interrupted.");
                    Thread.currentThread().interrupt();
                    return;
                }
            }
        }
    }

    /**
     * Resolves the PRNG seed: a fixed integer from {@code SEED}, or {@code 42}
     * when {@code SEED} is unset or blank. The default is deliberately fixed so a
     * plain {@code docker compose up} run is reproducible.
     */
    static long resolveSeed(String rawSeedEnv) {
        if (rawSeedEnv == null || rawSeedEnv.isBlank()) {
            return 42L;
        }
        return Long.parseLong(rawSeedEnv.trim());
    }

    /** Resolves an optional fixed ISO-8601 start instant, or launch time when blank. */
    static long resolveStartMillis(String rawStartTime, long launchMillis) {
        if (rawStartTime == null || rawStartTime.isBlank()) {
            return launchMillis;
        }
        try {
            return Instant.parse(rawStartTime.trim()).toEpochMilli();
        } catch (Exception e) {
            throw new IllegalArgumentException(
                    "START_TIME must be an ISO-8601 instant, was " + rawStartTime, e);
        }
    }

    /**
     * Maps raw {@code devices} documents (issue #70 registry shape) to engine
     * {@link Device}s: {@code deviceId}, {@code kind} and the ordered
     * {@code channels[].{channel, unit}} array.
     */
    static List<Device> parseDevices(List<Document> deviceDocuments) {
        List<Device> devices = new ArrayList<>();
        for (Document doc : deviceDocuments) {
            List<SimulatorEngine.Channel> channels = new ArrayList<>();
            List<Document> channelDocs = doc.getList("channels", Document.class);
            if (channelDocs != null) {
                for (Document channelDoc : channelDocs) {
                    channels.add(new SimulatorEngine.Channel(
                            channelDoc.getString("channel"),
                            channelDoc.getString("unit")));
                }
            }
            devices.add(new Device(
                    doc.getString("deviceId"),
                    doc.getString("kind"),
                    List.copyOf(channels)));
        }
        devices.sort(Comparator.comparing(Device::deviceId));
        return devices;
    }

    private static void writeBatch(MongoCollection<Document> collection, List<Reading> batch) {
        List<Document> documents = new ArrayList<>(batch.size());
        for (Reading reading : batch) {
            documents.add(new Document()
                    .append("deviceId", reading.deviceId())
                    .append("channel", reading.channel())
                    .append("value", reading.value())
                    .append("unit", reading.unit())
                    .append("timestamp", reading.timestamp()));
        }
        collection.insertMany(documents);
    }

    private static void sleepMillis(long millis) throws InterruptedException {
        if (millis > 0) {
            TimeUnit.MILLISECONDS.sleep(millis);
        }
    }

    private static List<Document> readAllDevices(MongoDatabase database) {
        List<Document> docs = new ArrayList<>();
        database.getCollection("devices").find()
                .sort(Sorts.ascending("deviceId"))
                .forEach(docs::add);
        return docs;
    }

    private static String env(String key, String fallback) {
        String value = ENV.get(key);
        return value == null || value.isBlank() ? fallback : value;
    }

    private static int envInt(String key, int fallback) {
        String value = ENV.get(key);
        return value == null || value.isBlank() ? fallback : Integer.parseInt(value.trim());
    }

    private static boolean envBool(String key, boolean fallback) {
        String value = ENV.get(key);
        return value == null || value.isBlank() ? fallback : Boolean.parseBoolean(value.trim());
    }
}
