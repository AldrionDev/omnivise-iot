package com.omnivise.simulator;

import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.OptionalDouble;
import java.util.Random;

/**
 * Pure, single-threaded signal model for the server-room simulator.
 *
 * <p>{@link #tick(long)} returns the readings for one simulated tick. Every value
 * is a deterministic function of the registry, the {@link Config} (fixed seed +
 * start instant + interval) and the tick index, so a run is fully reproducible
 * and unit-testable without MongoDB or a wall clock.
 *
 * <p>Signal model (deliberately lightweight, not a physics engine):
 * <ul>
 *   <li>a diurnal ambient curve drives rack {@code intake_temp};</li>
 *   <li>a slow synthetic rack {@code load} drives {@code power_draw} and, with
 *       intake, {@code exhaust_temp}; {@code fan_rpm} rises with {@code exhaust_temp};</li>
 *   <li>{@code pdu} {@code power_draw} follows the aggregate rack power and
 *       {@code current} is derived from power / line voltage;</li>
 *   <li>{@code ups} {@code load_pct} follows aggregate rack power; {@code crac}
 *       return temperature follows the mean rack exhaust;</li>
 *   <li>bounded Gaussian noise on every continuous channel; {@code door_contact}
 *       is mostly {@code "closed"} with rare, seed-deterministic opens.</li>
 * </ul>
 *
 * <p>Anomalies are a small explicit state machine
 * ({@code NORMAL -> ACTIVE -> RECOVERY -> NORMAL}), at most one at a time,
 * scenarios cycled round-robin. They are inert unless {@link Config#anomalyMode()}.
 */
public final class SimulatorEngine {

    /** A device from the seeded registry (issue #70 topology). */
    public record Device(String deviceId, String kind, List<Channel> channels) {
    }

    /** One channel of a device; {@code unit} is authoritative and never re-derived. */
    public record Channel(String name, String unit) {
    }

    /** One emitted reading; {@code timestamp} is a {@link Date} so it stores as a BSON Date. */
    public record Reading(String deviceId, String channel, Object value, String unit, Date timestamp) {
    }

    /** Observable snapshot of the anomaly state machine. */
    public record AnomalyInfo(String phase, String scenario, String deviceId, String channel) {
    }

    /**
     * Engine configuration.
     *
     * <p>Validated on construction (issue #71 finding B4): {@code intervalSeconds}
     * must be at least 1, and — only when {@code anomalyMode} is on —
     * {@code anomalyDurationTicks} must be at least 1 and
     * {@code anomalyEveryTicks} must be strictly greater than
     * {@code anomalyDurationTicks + recoveryTicks} (with
     * {@code recoveryTicks = max(2, anomalyDurationTicks / 2)}). Only then can the
     * next onset land in a NORMAL phase, so the configured cadence actually holds
     * with at most one anomaly active. With {@code anomalyMode} off the anomaly
     * values are inert and left unchecked.
     *
     * @param intervalSeconds      simulated seconds between ticks ({@code >= 1})
     * @param seed                 PRNG seed; equal seeds produce equal sequences
     * @param anomalyMode          when {@code false}, the engine never leaves NORMAL
     * @param anomalyEveryTicks    ticks between anomaly onsets
     * @param anomalyDurationTicks length of the ACTIVE window
     * @param anomalyScenarios     scenarios cycled round-robin on each onset
     *                             ({@code "breach_high"}, {@code "mains_loss"})
     * @param startEpochMillis     simulated instant of tick 0
     */
    public record Config(
            int intervalSeconds,
            long seed,
            boolean anomalyMode,
            int anomalyEveryTicks,
            int anomalyDurationTicks,
            List<String> anomalyScenarios,
            long startEpochMillis) {

        public Config {
            if (intervalSeconds < 1) {
                throw new IllegalArgumentException(
                        "INTERVAL_SECONDS must be >= 1, was " + intervalSeconds);
            }
            if (anomalyMode) {
                if (anomalyDurationTicks < 1) {
                    throw new IllegalArgumentException(
                            "ANOMALY_DURATION_TICKS must be >= 1 when ANOMALY_MODE is on, was "
                                    + anomalyDurationTicks);
                }
                int recovery = recoveryTicks(anomalyDurationTicks);
                int minEvery = anomalyDurationTicks + recovery + 1;
                if (anomalyEveryTicks < minEvery) {
                    throw new IllegalArgumentException(
                            "ANOMALY_EVERY_TICKS must be > ANOMALY_DURATION_TICKS + recoveryTicks ("
                                    + anomalyDurationTicks + " + " + recovery + "); need >= "
                                    + minEvery + ", was " + anomalyEveryTicks
                                    + " — otherwise the next onset falls inside ACTIVE/RECOVERY and"
                                    + " the configured cadence cannot hold");
                }
            }
        }

        /** Documented issue #71 defaults, with anomalies off. */
        public static Config defaults(long seed, long startEpochMillis) {
            return new Config(5, seed, false, 60, 6,
                    List.of("breach_high", "mains_loss"), startEpochMillis);
        }
    }

    /** Length of the RECOVERY phase for a given ACTIVE window: {@code max(2, duration / 2)}. */
    static int recoveryTicks(int anomalyDurationTicks) {
        return Math.max(2, anomalyDurationTicks / 2);
    }

    private static final double NOMINAL_LINE_VOLTAGE = 230.0;

    private final List<Device> registry;
    private final Config config;
    private final Random random;
    private final int recoveryTicks;
    private final List<String[]> breachTargets;

    // State carried across ticks.
    private final Map<String, Double> lastLoad = new LinkedHashMap<>();
    private final Map<String, Double> batteryPct = new LinkedHashMap<>();
    private final Map<String, Integer> doorOpenRemaining = new LinkedHashMap<>();

    private String anomalyPhase = "NORMAL";
    private String anomalyScenario;
    private String anomalyDeviceId;
    private String anomalyChannel;
    private long anomalyActiveUntil;
    private long anomalyRecoveryUntil;
    private int anomalyTriggerCount;

    public SimulatorEngine(List<Device> registry, Config config) {
        this.registry = List.copyOf(registry);
        this.config = config;
        this.random = new Random(config.seed());
        this.recoveryTicks = recoveryTicks(config.anomalyDurationTicks());
        this.breachTargets = buildBreachTargets(this.registry);
    }

    /** Readings for one tick, in registry order (device order, then channel order). */
    public List<Reading> tick(long tickIndex) {
        advanceAnomaly(tickIndex);

        double simSeconds = config.startEpochMillis() / 1000.0 + tickIndex * config.intervalSeconds();
        long secondsOfDay = Math.floorMod((long) simSeconds, 86_400L);
        double ambient = diurnalAmbient(secondsOfDay);
        Date timestamp = new Date(config.startEpochMillis() + tickIndex * config.intervalSeconds() * 1000L);

        Map<String, Map<String, Object>> values = new LinkedHashMap<>();

        // --- racks: also accumulate the aggregates the other kinds depend on ---
        double totalRackPower = 0.0;
        double sumExhaust = 0.0;
        int rackCount = 0;
        for (Device device : registry) {
            if (!"rack".equals(device.kind())) {
                continue;
            }
            Map<String, Object> ch = channelMap(values, device.deviceId());

            double intake = clamp(ambient + perDeviceOffset(device.deviceId(), 1.2) + noise(0.15), 12.0, 32.0);
            double load = clamp(0.55 + 0.18 * Math.sin(2 * Math.PI * simSeconds / (4 * 3600.0)
                    + perDevicePhase(device.deviceId())) + noise(0.03), 0.30, 0.85);
            lastLoad.put(device.deviceId(), load);

            double power = clamp(700.0 + 1200.0 * load + noise(15.0), 400.0, 2600.0);
            double exhaust = clamp(intake + 6.0 + 8.0 * load + noise(0.2), 16.0, 45.0);
            double fanFraction = clamp((exhaust - 26.0) / (42.0 - 26.0), 0.0, 1.0);
            double fanRpm = clamp(2200.0 + (6000.0 - 2200.0) * fanFraction + noise(25.0), 800.0, 7200.0);
            double humidity = clamp(44.0 + 3.0 * Math.sin(2 * Math.PI * simSeconds / (6 * 3600.0)
                    + perDevicePhase(device.deviceId())) - 0.4 * (intake - 21.5) + noise(0.3), 20.0, 70.0);

            ch.put("intake_temp", round1(intake));
            ch.put("exhaust_temp", round1(exhaust));
            ch.put("humidity", round1(humidity));
            ch.put("power_draw", round0(power));
            ch.put("fan_rpm", round0(fanRpm));
            ch.put("door_contact", doorContact(device.deviceId()));

            totalRackPower += power;
            sumExhaust += exhaust;
            rackCount++;
        }
        double meanExhaust = rackCount > 0 ? sumExhaust / rackCount : 30.0;

        // --- ups ---
        boolean mainsLoss = mainsLossActive();
        double lineVoltage = NOMINAL_LINE_VOLTAGE;
        for (Device device : registry) {
            if (!"ups".equals(device.kind())) {
                continue;
            }
            Map<String, Object> ch = channelMap(values, device.deviceId());

            double inputVoltage = mainsLoss
                    ? clamp(2.0 + noise(1.0), 0.0, 10.0)
                    : clamp(NOMINAL_LINE_VOLTAGE + noise(0.4), 0.0, 245.0);
            double loadPct = clamp(100.0 * totalRackPower / 6800.0 + noise(0.5), 0.0, 100.0);

            double battery = batteryPct.getOrDefault(device.deviceId(), 100.0);
            battery = clamp(battery + (mainsLoss ? -2.5 : 1.0), 0.0, 100.0);
            batteryPct.put(device.deviceId(), battery);

            ch.put("load_pct", round1(loadPct));
            ch.put("battery_pct", round1(battery));
            ch.put("input_voltage", round1(inputVoltage));

            if (inputVoltage > 180.0) {
                lineVoltage = inputVoltage;
            }
        }

        // --- pdu ---
        for (Device device : registry) {
            if (!"pdu".equals(device.kind())) {
                continue;
            }
            Map<String, Object> ch = channelMap(values, device.deviceId());
            double pduPower = clamp(0.95 * totalRackPower + noise(20.0), 800.0, 5200.0);
            double current = clamp(pduPower / lineVoltage + noise(0.05), 0.0, 25.0);
            ch.put("power_draw", round0(pduPower));
            ch.put("current", round1(current));
        }

        // --- crac ---
        for (Device device : registry) {
            if (!"crac".equals(device.kind())) {
                continue;
            }
            Map<String, Object> ch = channelMap(values, device.deviceId());
            double supply = clamp(18.0 + noise(0.15), 10.0, 26.0);
            double ret = clamp(meanExhaust - 5.0 + noise(0.2), 14.0, 42.0);
            double fanFraction = clamp((ret - 22.0) / (34.0 - 22.0), 0.0, 1.0);
            double fanRpm = clamp(2000.0 + (5000.0 - 2000.0) * fanFraction + noise(25.0), 600.0, 6200.0);
            ch.put("supply_temp", round1(supply));
            ch.put("return_temp", round1(ret));
            ch.put("fan_rpm", round0(fanRpm));
        }

        applyBreachOverlay(values);

        // --- assemble in registry order, filling any unmodelled channel generically ---
        List<Reading> readings = new ArrayList<>();
        for (Device device : registry) {
            Map<String, Object> ch = values.getOrDefault(device.deviceId(), Map.of());
            for (Channel channel : device.channels()) {
                Object value = ch.get(channel.name());
                if (value == null) {
                    value = round1(clamp(50.0 + noise(1.0), 0.0, 100.0));
                }
                readings.add(new Reading(device.deviceId(), channel.name(), value, channel.unit(), timestamp));
            }
        }
        return readings;
    }

    /** Current anomaly, or empty while in NORMAL. */
    public Optional<AnomalyInfo> currentAnomaly() {
        if ("NORMAL".equals(anomalyPhase)) {
            return Optional.empty();
        }
        return Optional.of(new AnomalyInfo(anomalyPhase, anomalyScenario, anomalyDeviceId, anomalyChannel));
    }

    /** Last synthetic load computed for a rack device, for correlation assertions. */
    public OptionalDouble lastLoad(String deviceId) {
        Double value = lastLoad.get(deviceId);
        return value == null ? OptionalDouble.empty() : OptionalDouble.of(value);
    }

    // ------------------------------------------------------------------
    // Anomaly state machine
    // ------------------------------------------------------------------

    private void advanceAnomaly(long tickIndex) {
        switch (anomalyPhase) {
            case "NORMAL" -> {
                if (config.anomalyMode()
                        && !config.anomalyScenarios().isEmpty()
                        && tickIndex > 0
                        && tickIndex % config.anomalyEveryTicks() == 0) {
                    startAnomaly(tickIndex);
                }
            }
            case "ACTIVE" -> {
                if (tickIndex >= anomalyActiveUntil) {
                    anomalyPhase = "RECOVERY";
                    anomalyRecoveryUntil = tickIndex + recoveryTicks;
                }
            }
            case "RECOVERY" -> {
                if (tickIndex >= anomalyRecoveryUntil) {
                    anomalyPhase = "NORMAL";
                    anomalyScenario = null;
                    anomalyDeviceId = null;
                    anomalyChannel = null;
                }
            }
            default -> throw new IllegalStateException("unknown anomaly phase: " + anomalyPhase);
        }
    }

    private void startAnomaly(long tickIndex) {
        List<String> scenarios = config.anomalyScenarios();
        String scenario = scenarios.get(anomalyTriggerCount % scenarios.size());
        anomalyTriggerCount++;
        anomalyPhase = "ACTIVE";
        anomalyScenario = scenario;
        anomalyActiveUntil = tickIndex + config.anomalyDurationTicks();

        if ("mains_loss".equals(scenario)) {
            anomalyDeviceId = firstDeviceOfKind("ups");
            anomalyChannel = "battery_pct";
        } else {
            String[] target = breachTargets.isEmpty()
                    ? new String[] {firstDeviceId(), firstChannelName()}
                    : breachTargets.get(random.nextInt(breachTargets.size()));
            anomalyDeviceId = target[0];
            anomalyChannel = target[1];
        }
    }

    private boolean mainsLossActive() {
        return "ACTIVE".equals(anomalyPhase) && "mains_loss".equals(anomalyScenario);
    }

    private void applyBreachOverlay(Map<String, Map<String, Object>> values) {
        if (!"ACTIVE".equals(anomalyPhase) || !"breach_high".equals(anomalyScenario)) {
            return;
        }
        Map<String, Object> ch = values.get(anomalyDeviceId);
        if (ch == null || !(ch.get(anomalyChannel) instanceof Number normal)) {
            return;
        }
        String unit = unitOf(anomalyDeviceId, anomalyChannel);
        double breached = breachHigh(normal.doubleValue(), unit);
        ch.put(anomalyChannel, "W".equals(unit) || "rpm".equals(unit) ? round0(breached) : round1(breached));
    }

    private static double breachHigh(double normal, String unit) {
        return switch (unit) {
            case "°C" -> normal + 15.0;
            case "rpm" -> normal + 2800.0;
            case "W", "A" -> normal * 1.8;
            case "%" -> Math.min(normal + 35.0, 99.0);
            default -> normal * 1.6;
        };
    }

    // ------------------------------------------------------------------
    // Signal helpers
    // ------------------------------------------------------------------

    private static double diurnalAmbient(long secondsOfDay) {
        double dayFraction = secondsOfDay / 86_400.0;
        // Trough ~03:00, peak ~15:00.
        return 21.5 + 2.5 * Math.sin(2 * Math.PI * (dayFraction - 0.375));
    }

    private String doorContact(String deviceId) {
        int remaining = doorOpenRemaining.getOrDefault(deviceId, 0);
        if (remaining > 0) {
            doorOpenRemaining.put(deviceId, remaining - 1);
            return "open";
        }
        if (random.nextDouble() < 0.01) {
            doorOpenRemaining.put(deviceId, random.nextInt(3)); // 0..2 further ticks -> 1..3 total
            return "open";
        }
        return "closed";
    }

    /** Gaussian noise with standard deviation {@code sigma}, clamped to +/- 3 sigma. */
    private double noise(double sigma) {
        double g = random.nextGaussian() * sigma;
        return Math.max(-3.0 * sigma, Math.min(3.0 * sigma, g));
    }

    private static double clamp(double value, double lo, double hi) {
        return Math.max(lo, Math.min(hi, value));
    }

    private static double round1(double value) {
        return Math.round(value * 10.0) / 10.0;
    }

    private static double round0(double value) {
        return (double) Math.round(value);
    }

    private static double perDevicePhase(String deviceId) {
        return Math.floorMod(deviceId.hashCode(), 1000) / 1000.0 * 2 * Math.PI;
    }

    private static double perDeviceOffset(String deviceId, double maxOffset) {
        return Math.floorMod(deviceId.hashCode() * 31, 1000) / 1000.0 * maxOffset;
    }

    // ------------------------------------------------------------------
    // Registry helpers
    // ------------------------------------------------------------------

    private static Map<String, Object> channelMap(Map<String, Map<String, Object>> values, String deviceId) {
        return values.computeIfAbsent(deviceId, k -> new LinkedHashMap<>());
    }

    private static List<String[]> buildBreachTargets(List<Device> registry) {
        List<String[]> targets = new ArrayList<>();
        for (Device device : registry) {
            for (Channel channel : device.channels()) {
                if (channel.name().equals("battery_pct") || channel.name().equals("door_contact")) {
                    continue;
                }
                switch (channel.unit()) {
                    case "°C", "%", "W", "rpm", "A" -> targets.add(new String[] {device.deviceId(), channel.name()});
                    default -> { /* voltage etc. is not a "breach high" target */ }
                }
            }
        }
        return targets;
    }

    private String firstDeviceOfKind(String kind) {
        for (Device device : registry) {
            if (kind.equals(device.kind())) {
                return device.deviceId();
            }
        }
        return firstDeviceId();
    }

    private String firstDeviceId() {
        return registry.get(0).deviceId();
    }

    private String firstChannelName() {
        return registry.get(0).channels().get(0).name();
    }

    private String unitOf(String deviceId, String channelName) {
        for (Device device : registry) {
            if (!device.deviceId().equals(deviceId)) {
                continue;
            }
            for (Channel channel : device.channels()) {
                if (channel.name().equals(channelName)) {
                    return channel.unit();
                }
            }
        }
        return "";
    }
}
