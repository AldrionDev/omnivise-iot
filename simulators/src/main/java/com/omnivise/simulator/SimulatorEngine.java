package com.omnivise.simulator;

import java.util.ArrayList;
import java.util.Date;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
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
 * <p>Anomalies are bounded concurrent instances with explicit ACTIVE and
 * RECOVERY deadlines. Scenarios cycle round-robin and are inert unless
 * {@link Config#anomalyMode()}.
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

    /** Observable snapshot of one anomaly instance. */
    public record AnomalyInfo(long id, String phase, String scenario, String deviceId, String channel) {
    }

    /**
     * Engine configuration.
     *
     * <p>All scalar bounds are validated on construction. When anomaly mode is
     * enabled, the configured cadence must also have enough lifecycle capacity
     * for every scheduled onset.
     *
     * @param intervalSeconds      simulated seconds between ticks ({@code >= 1})
     * @param seed                 PRNG seed; equal seeds produce equal sequences
     * @param anomalyMode          when {@code false}, the engine never leaves NORMAL
     * @param anomalyEveryTicks    ticks between anomaly onsets
     * @param anomalyDurationTicks length of the ACTIVE window
     * @param anomalyRecoveryTicks length of the RECOVERY window; {@code null}
     *                             derives {@code max(2, duration / 2)}
     * @param maxConcurrentAnomalies maximum simultaneous ACTIVE/RECOVERY instances
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
            Integer anomalyRecoveryTicks,
            int maxConcurrentAnomalies,
            List<String> anomalyScenarios,
            long startEpochMillis) {

        public Config {
            if (intervalSeconds < 1) {
                throw new IllegalArgumentException(
                        "INTERVAL_SECONDS must be >= 1, was " + intervalSeconds);
            }
            if (anomalyEveryTicks < 1) {
                throw new IllegalArgumentException(
                        "ANOMALY_EVERY_TICKS must be >= 1, was " + anomalyEveryTicks);
            }
            if (anomalyDurationTicks < 1) {
                throw new IllegalArgumentException(
                        "ANOMALY_DURATION_TICKS must be >= 1, was " + anomalyDurationTicks);
            }
            if (anomalyRecoveryTicks == null) {
                anomalyRecoveryTicks = recoveryTicks(anomalyDurationTicks);
            }
            if (anomalyRecoveryTicks < 1) {
                throw new IllegalArgumentException(
                        "ANOMALY_RECOVERY_TICKS must be >= 1, was " + anomalyRecoveryTicks);
            }
            if (maxConcurrentAnomalies < 1 || maxConcurrentAnomalies > 2) {
                throw new IllegalArgumentException(
                        "MAX_CONCURRENT_ANOMALIES must be 1 or 2, was "
                                + maxConcurrentAnomalies);
            }
            long lifecycleTicks = (long) anomalyDurationTicks + anomalyRecoveryTicks;
            long availableTicks = (long) anomalyEveryTicks * maxConcurrentAnomalies;
            if (anomalyMode && lifecycleTicks > availableTicks) {
                throw new IllegalArgumentException(
                        "ANOMALY_DURATION_TICKS + ANOMALY_RECOVERY_TICKS must be <= "
                                + "ANOMALY_EVERY_TICKS * MAX_CONCURRENT_ANOMALIES, was "
                                + lifecycleTicks + " > " + availableTicks);
            }
        }

        /** Compatibility constructor deriving recovery from the ACTIVE duration. */
        public Config(
                int intervalSeconds,
                long seed,
                boolean anomalyMode,
                int anomalyEveryTicks,
                int anomalyDurationTicks,
                int maxConcurrentAnomalies,
                List<String> anomalyScenarios,
                long startEpochMillis) {
            this(intervalSeconds, seed, anomalyMode, anomalyEveryTicks,
                    anomalyDurationTicks, null, maxConcurrentAnomalies,
                    anomalyScenarios, startEpochMillis);
        }

        /** Documented defaults, with anomalies off and compatibility-derived recovery. */
        public static Config defaults(long seed, long startEpochMillis) {
            return new Config(5, seed, false, 60, 6, null, 1,
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
    private final List<ChannelRef> breachTargets;
    private final List<ChannelRef> mainsLossFootprint;

    // State carried across ticks.
    private final Map<String, Double> lastLoad = new LinkedHashMap<>();
    private final Map<String, Double> batteryPct = new LinkedHashMap<>();
    private final Map<String, Integer> doorOpenRemaining = new LinkedHashMap<>();

    private final List<AnomalyInstance> anomalies = new ArrayList<>();
    private int scenarioCursor;
    private long nextAnomalyId = 1;
    private long currentTick = -1;

    private record ChannelRef(String deviceId, String channel) {
    }

    private record AnomalyInstance(
            long id,
            String scenario,
            ChannelRef displayTarget,
            List<ChannelRef> footprint,
            long startTick,
            long activeUntil,
            long recoveryUntil) {

        String phase(long tickIndex) {
            return tickIndex < activeUntil ? "ACTIVE" : "RECOVERY";
        }
    }

    public SimulatorEngine(List<Device> registry, Config config) {
        this.registry = List.copyOf(registry);
        this.config = config;
        this.random = new Random(config.seed());
        this.recoveryTicks = config.anomalyRecoveryTicks();
        this.breachTargets = buildBreachTargets(this.registry);
        this.mainsLossFootprint = buildMainsLossFootprint(this.registry);
    }

    /** Readings for one tick, in registry order (device order, then channel order). */
    public List<Reading> tick(long tickIndex) {
        currentTick = tickIndex;
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
        double lineVoltage = NOMINAL_LINE_VOLTAGE;
        for (Device device : registry) {
            if (!"ups".equals(device.kind())) {
                continue;
            }
            Map<String, Object> ch = channelMap(values, device.deviceId());

            boolean inputVoltageAffected = activeAnomalyAffects(device.deviceId(), "input_voltage", "mains_loss");
            boolean batteryAffected = activeAnomalyAffects(device.deviceId(), "battery_pct", "mains_loss");
            double inputVoltage = inputVoltageAffected
                    ? clamp(2.0 + noise(1.0), 0.0, 10.0)
                    : clamp(NOMINAL_LINE_VOLTAGE + noise(0.4), 0.0, 245.0);
            double loadPct = clamp(100.0 * totalRackPower / 6800.0 + noise(0.5), 0.0, 100.0);

            double battery = batteryPct.getOrDefault(device.deviceId(), 100.0);
            battery = clamp(battery + (batteryAffected ? -2.5 : 1.0), 0.0, 100.0);
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

    /** Immutable current anomaly snapshot in deterministic admission/ID order. */
    public List<AnomalyInfo> currentAnomalies() {
        return anomalies.stream()
                .map(anomaly -> new AnomalyInfo(
                        anomaly.id(),
                        anomaly.phase(currentTick),
                        anomaly.scenario(),
                        anomaly.displayTarget().deviceId(),
                        anomaly.displayTarget().channel()))
                .toList();
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
        anomalies.removeIf(anomaly -> tickIndex >= anomaly.recoveryUntil());

        if (config.anomalyMode()
                && !config.anomalyScenarios().isEmpty()
                && anomalies.size() < config.maxConcurrentAnomalies()
                && tickIndex > 0
                && tickIndex % config.anomalyEveryTicks() == 0) {
            admitAnomaly(tickIndex);
        }
    }

    private void admitAnomaly(long tickIndex) {
        List<String> scenarios = config.anomalyScenarios();
        String scenario = scenarios.get(scenarioCursor % scenarios.size());
        ChannelRef displayTarget;
        List<ChannelRef> footprint;

        if ("mains_loss".equals(scenario)) {
            footprint = mainsLossFootprint;
            if (footprint.isEmpty() || intersectsReservedFootprint(footprint)) {
                return;
            }
            displayTarget = footprint.stream()
                    .filter(target -> "battery_pct".equals(target.channel()))
                    .findFirst()
                    .orElse(footprint.get(0));
        } else {
            displayTarget = selectBreachTarget();
            if (displayTarget == null) {
                return;
            }
            footprint = List.of(displayTarget);
        }

        long activeUntil = tickIndex + config.anomalyDurationTicks();
        anomalies.add(new AnomalyInstance(
                nextAnomalyId++,
                scenario,
                displayTarget,
                footprint,
                tickIndex,
                activeUntil,
                activeUntil + recoveryTicks));
        scenarioCursor++;
    }

    private ChannelRef selectBreachTarget() {
        if (breachTargets.isEmpty()) {
            return null;
        }
        boolean hasAvailableTarget = breachTargets.stream()
                .anyMatch(target -> !isReserved(target));
        if (!hasAvailableTarget) {
            return null;
        }

        int start = random.nextInt(breachTargets.size());
        for (int offset = 0; offset < breachTargets.size(); offset++) {
            ChannelRef target = breachTargets.get((start + offset) % breachTargets.size());
            if (!isReserved(target)) {
                return target;
            }
        }
        throw new IllegalStateException("available breach target was not found");
    }

    private boolean intersectsReservedFootprint(List<ChannelRef> footprint) {
        return footprint.stream().anyMatch(this::isReserved);
    }

    private boolean isReserved(ChannelRef target) {
        return anomalies.stream().anyMatch(anomaly -> anomaly.footprint().contains(target));
    }

    private boolean activeAnomalyAffects(String deviceId, String channel, String scenario) {
        ChannelRef target = new ChannelRef(deviceId, channel);
        return anomalies.stream().anyMatch(anomaly ->
                scenario.equals(anomaly.scenario())
                        && "ACTIVE".equals(anomaly.phase(currentTick))
                        && anomaly.footprint().contains(target));
    }

    private void applyBreachOverlay(Map<String, Map<String, Object>> values) {
        for (AnomalyInstance anomaly : anomalies) {
            if (!"ACTIVE".equals(anomaly.phase(currentTick)) || !"breach_high".equals(anomaly.scenario())) {
                continue;
            }
            ChannelRef target = anomaly.displayTarget();
            Map<String, Object> ch = values.get(target.deviceId());
            if (ch == null || !(ch.get(target.channel()) instanceof Number normal)) {
                continue;
            }
            String unit = unitOf(target.deviceId(), target.channel());
            double breached = breachHigh(normal.doubleValue(), unit);
            ch.put(target.channel(), "W".equals(unit) || "rpm".equals(unit)
                    ? round0(breached) : round1(breached));
        }
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

    private static List<ChannelRef> buildBreachTargets(List<Device> registry) {
        List<ChannelRef> targets = new ArrayList<>();
        for (Device device : registry) {
            for (Channel channel : device.channels()) {
                boolean canonicalWarningTarget =
                        ("rack".equals(device.kind())
                                && ("intake_temp".equals(channel.name()) || "humidity".equals(channel.name())))
                        || ("crac".equals(device.kind()) && "return_temp".equals(channel.name()));

                if (canonicalWarningTarget) {
                    targets.add(new ChannelRef(device.deviceId(), channel.name()));
                }
            }
        }
        return List.copyOf(targets);
    }

    private static List<ChannelRef> buildMainsLossFootprint(List<Device> registry) {
        List<ChannelRef> footprint = new ArrayList<>();
        for (Device device : registry) {
            if (!"ups".equals(device.kind())) {
                continue;
            }
            for (Channel channel : device.channels()) {
                if ("battery_pct".equals(channel.name()) || "input_voltage".equals(channel.name())) {
                    footprint.add(new ChannelRef(device.deviceId(), channel.name()));
                }
            }
        }
        return List.copyOf(footprint);
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
