package com.omnivise.simulator;

import java.util.ArrayList;
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
 * parsing, Mongo I/O and the tick loop. The loop runs on an <em>absolute</em>
 * schedule (tick {@code k} is due at {@code start + (k + 1) * interval}) so the
 * real execution stays on the same grid as the deterministic generated
 * timestamps and processing time never accumulates into drift.
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
        long startMillis = System.currentTimeMillis();

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
     * The tick loop. Tick {@code k} is due at
     * {@code startMillis + (k + 1) * intervalSeconds * 1000}; after producing and
     * sinking a tick we sleep only until that absolute instant (clamped to zero
     * if the work overran), so processing time is corrected every tick instead of
     * accumulating. Single-threaded, plain loop — no scheduler.
     *
     * @param engine          the deterministic signal model
     * @param sink            consumes one tick's readings (Mongo write in production)
     * @param intervalSeconds simulated seconds per tick
     * @param startMillis     wall-clock instant of tick 0 (also the engine's start)
     * @param clock           current wall-clock millis
     * @param sleeper         blocks for the requested millis
     * @param maxTicks        stop after this many ticks ({@link Long#MAX_VALUE} in production)
     */
    static void runLoop(SimulatorEngine engine,
            Consumer<List<Reading>> sink,
            int intervalSeconds,
            long startMillis,
            LongSupplier clock,
            Sleeper sleeper,
            long maxTicks) {
        long intervalMillis = intervalSeconds * 1000L;
        for (long tick = 0; tick < maxTicks; tick++) {
            try {
                List<Reading> batch = engine.tick(tick);
                sink.accept(batch);
                engine.currentAnomaly().ifPresent(a -> System.out.printf(
                        "  ⚠️  anomaly %s [%s] %s/%s%n", a.scenario(), a.phase(), a.deviceId(), a.channel()));
                System.out.printf("[tick %d] ✅ inserted %d readings%n", tick, batch.size());

                long nextTickInstant = startMillis + (tick + 1) * intervalMillis;
                long remaining = nextTickInstant - clock.getAsLong();
                sleeper.sleep(Math.max(0L, remaining));
            } catch (InterruptedException e) {
                System.err.println("⚠️ Simulation interrupted.");
                Thread.currentThread().interrupt();
                return;
            } catch (Exception e) {
                System.err.println("❌ Error during tick: " + e.getMessage());
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
        database.getCollection("devices").find().forEach(docs::add);
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
