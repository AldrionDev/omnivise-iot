package com.omnivise.simulator;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import org.junit.jupiter.api.Test;

import com.omnivise.simulator.SimulatorEngine.AnomalyInfo;
import com.omnivise.simulator.SimulatorEngine.Channel;
import com.omnivise.simulator.SimulatorEngine.Config;
import com.omnivise.simulator.SimulatorEngine.Device;
import com.omnivise.simulator.SimulatorEngine.Reading;

/**
 * Behavioural tests for {@link SimulatorEngine}.
 *
 * <p>The engine is a pure, single-threaded signal model: given a device registry
 * and a {@link Config} (fixed seed + start instant), {@link SimulatorEngine#tick(long)}
 * returns the readings for one simulated tick. No MongoDB, no sleeping, no wall
 * clock — so every property below is reproducible.
 */
class SimulatorEngineTest {

    /** Fixed simulated start instant; midnight keeps diurnal maths easy to reason about. */
    private static final long START_EPOCH_MILLIS = Instant.parse("2026-09-10T00:00:00Z").toEpochMilli();

    /**
     * The approved issue #70 server-room topology (device id / kind / channel /
     * unit), expressed directly as engine input so the tests do not depend on a
     * live MongoDB or on {@code mongo-init.js}.
     */
    private static List<Device> serverRoomRegistry() {
        List<Channel> rackChannels = List.of(
                new Channel("intake_temp", "°C"),
                new Channel("exhaust_temp", "°C"),
                new Channel("humidity", "%"),
                new Channel("power_draw", "W"),
                new Channel("fan_rpm", "rpm"),
                new Channel("door_contact", "state"));
        return List.of(
                new Device("rack-a1", "rack", rackChannels),
                new Device("rack-a2", "rack", rackChannels),
                new Device("ups-1", "ups", List.of(
                        new Channel("load_pct", "%"),
                        new Channel("battery_pct", "%"),
                        new Channel("input_voltage", "V"))),
                new Device("pdu-a1", "pdu", List.of(
                        new Channel("power_draw", "W"),
                        new Channel("current", "A"))),
                new Device("crac-1", "crac", List.of(
                        new Channel("supply_temp", "°C"),
                        new Channel("return_temp", "°C"),
                        new Channel("fan_rpm", "rpm"))));
    }

    private static SimulatorEngine engine(Config config) {
        return new SimulatorEngine(serverRoomRegistry(), config);
    }

    /** Physically sensible envelopes for the continuous channels, keyed by "deviceId/channel". */
    private static final Map<String, double[]> BOUNDS = Map.ofEntries(
            Map.entry("rack-a1/intake_temp", new double[] {12.0, 32.0}),
            Map.entry("rack-a1/exhaust_temp", new double[] {16.0, 45.0}),
            Map.entry("rack-a1/humidity", new double[] {20.0, 70.0}),
            Map.entry("rack-a1/power_draw", new double[] {400.0, 2600.0}),
            Map.entry("rack-a1/fan_rpm", new double[] {800.0, 7200.0}),
            Map.entry("rack-a2/intake_temp", new double[] {12.0, 32.0}),
            Map.entry("rack-a2/exhaust_temp", new double[] {16.0, 45.0}),
            Map.entry("rack-a2/humidity", new double[] {20.0, 70.0}),
            Map.entry("rack-a2/power_draw", new double[] {400.0, 2600.0}),
            Map.entry("rack-a2/fan_rpm", new double[] {800.0, 7200.0}),
            Map.entry("ups-1/load_pct", new double[] {0.0, 100.0}),
            Map.entry("ups-1/battery_pct", new double[] {0.0, 100.0}),
            Map.entry("ups-1/input_voltage", new double[] {0.0, 245.0}),
            Map.entry("pdu-a1/power_draw", new double[] {800.0, 5200.0}),
            Map.entry("pdu-a1/current", new double[] {0.0, 25.0}),
            Map.entry("crac-1/supply_temp", new double[] {10.0, 26.0}),
            Map.entry("crac-1/return_temp", new double[] {14.0, 42.0}),
            Map.entry("crac-1/fan_rpm", new double[] {600.0, 6200.0}));

    private static double asDouble(Object value) {
        return ((Number) value).doubleValue();
    }

    @Test
    void timestampIsADateAtTheExpectedTickInstant() {
        SimulatorEngine engine = engine(Config.defaults(42L, START_EPOCH_MILLIS));

        for (long tick : new long[] {0, 1, 7, 123}) {
            List<Reading> readings = engine.tick(tick);
            long expected = START_EPOCH_MILLIS + tick * 5_000L;
            for (Reading r : readings) {
                assertInstanceOf(java.util.Date.class, r.timestamp(), "timestamp stores as BSON Date");
                assertEquals(expected, r.timestamp().getTime(), r.deviceId() + "/" + r.channel());
            }
        }
    }

    private static double valueOf(List<Reading> readings, String deviceId, String channel) {
        return readings.stream()
                .filter(r -> r.deviceId().equals(deviceId) && r.channel().equals(channel))
                .map(r -> asDouble(r.value()))
                .findFirst()
                .orElseThrow();
    }

    /** Pearson correlation coefficient of two equal-length series. */
    private static double correlation(double[] x, double[] y) {
        int n = x.length;
        double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
        for (int i = 0; i < n; i++) {
            sx += x[i];
            sy += y[i];
            sxx += x[i] * x[i];
            syy += y[i] * y[i];
            sxy += x[i] * y[i];
        }
        double cov = n * sxy - sx * sy;
        double denom = Math.sqrt((n * sxx - sx * sx) * (n * syy - sy * sy));
        return cov / denom;
    }

    @Test
    void intakeTempFollowsADiurnalCurveNotUniformRandomness() {
        SimulatorEngine engine = engine(Config.defaults(11L, START_EPOCH_MILLIS));

        // Sample 120 ticks (10 min) around 05:00 and around 15:00. Interval is 5s
        // and the run starts at midnight, so hour H begins at tick H * 720.
        double sumAt05 = 0, sumAt15 = 0;
        double prev = Double.NaN;
        double maxStep = 0;
        for (long tick = 0; tick <= 15_120; tick++) {
            List<Reading> readings = engine.tick(tick);
            double intake = valueOf(readings, "rack-a1", "intake_temp");
            if (tick >= 5 * 720 && tick < 5 * 720 + 120) {
                sumAt05 += intake;
            }
            if (tick >= 15 * 720 && tick < 15 * 720 + 120) {
                sumAt15 += intake;
            }
            if (!Double.isNaN(prev)) {
                maxStep = Math.max(maxStep, Math.abs(intake - prev));
            }
            prev = intake;
        }
        double meanAt05 = sumAt05 / 120.0;
        double meanAt15 = sumAt15 / 120.0;

        assertTrue(meanAt15 - meanAt05 > 2.0,
                "afternoon intake should be clearly warmer than pre-dawn: 15:00=" + meanAt15 + " 05:00=" + meanAt05);
        assertTrue(maxStep < 1.5,
                "tick-to-tick change should be small (structured signal, not white noise): maxStep=" + maxStep);
    }

    @Test
    void higherSyntheticLoadYieldsHigherRackPowerDraw() {
        SimulatorEngine engine = engine(Config.defaults(3L, START_EPOCH_MILLIS));
        int n = 2_000;
        double[] load = new double[n];
        double[] power = new double[n];
        for (int i = 0; i < n; i++) {
            List<Reading> readings = engine.tick(i);
            load[i] = engine.lastLoad("rack-a1").orElseThrow();
            power[i] = valueOf(readings, "rack-a1", "power_draw");
        }
        assertTrue(correlation(load, power) > 0.6, "corr(load, power_draw) = " + correlation(load, power));
    }

    @Test
    void higherSyntheticLoadYieldsHigherExhaustTemp() {
        SimulatorEngine engine = engine(Config.defaults(4L, START_EPOCH_MILLIS));
        int n = 2_000;
        double[] load = new double[n];
        double[] exhaust = new double[n];
        for (int i = 0; i < n; i++) {
            List<Reading> readings = engine.tick(i);
            load[i] = engine.lastLoad("rack-a1").orElseThrow();
            exhaust[i] = valueOf(readings, "rack-a1", "exhaust_temp");
        }
        assertTrue(correlation(load, exhaust) > 0.3, "corr(load, exhaust_temp) = " + correlation(load, exhaust));
    }

    @Test
    void fanRpmRisesWithExhaustTemp() {
        SimulatorEngine engine = engine(Config.defaults(5L, START_EPOCH_MILLIS));
        int n = 2_000;
        double[] exhaust = new double[n];
        double[] fan = new double[n];
        for (int i = 0; i < n; i++) {
            List<Reading> readings = engine.tick(i);
            exhaust[i] = valueOf(readings, "rack-a1", "exhaust_temp");
            fan[i] = valueOf(readings, "rack-a1", "fan_rpm");
        }
        assertTrue(correlation(exhaust, fan) > 0.5, "corr(exhaust_temp, fan_rpm) = " + correlation(exhaust, fan));
    }

    @Test
    void pduCurrentTracksPduPowerDraw() {
        SimulatorEngine engine = engine(Config.defaults(6L, START_EPOCH_MILLIS));
        int n = 2_000;
        double[] power = new double[n];
        double[] current = new double[n];
        for (int i = 0; i < n; i++) {
            List<Reading> readings = engine.tick(i);
            power[i] = valueOf(readings, "pdu-a1", "power_draw");
            current[i] = valueOf(readings, "pdu-a1", "current");
        }
        assertTrue(correlation(power, current) > 0.8, "corr(power_draw, current) = " + correlation(power, current));
    }

    private static List<Reading> runTicks(SimulatorEngine engine, int ticks) {
        List<Reading> all = new java.util.ArrayList<>();
        for (int i = 0; i < ticks; i++) {
            all.addAll(engine.tick(i));
        }
        return all;
    }

    @Test
    void sameSeedProducesAnIdenticalSequence() {
        Config config = Config.defaults(42L, START_EPOCH_MILLIS);
        List<Reading> first = runTicks(engine(config), 300);
        List<Reading> second = runTicks(engine(config), 300);
        assertEquals(first, second, "a fixed SEED must reproduce the run byte for byte");
    }

    @Test
    void differentSeedChangesTheSequence() {
        List<Reading> a = runTicks(engine(Config.defaults(42L, START_EPOCH_MILLIS)), 300);
        List<Reading> b = runTicks(engine(Config.defaults(43L, START_EPOCH_MILLIS)), 300);
        assertEquals(a.size(), b.size());
        assertFalse(a.equals(b), "a different SEED must change the generated values");
    }

    @Test
    void doorContactIsPredominantlyClosedWithDeterministicOccasionalOpens() {
        Config config = Config.defaults(9L, START_EPOCH_MILLIS);
        int ticks = 5_000;

        List<String> firstRun = new java.util.ArrayList<>();
        int opens = 0;
        SimulatorEngine engine = engine(config);
        for (int i = 0; i < ticks; i++) {
            String state = engine.tick(i).stream()
                    .filter(r -> r.deviceId().equals("rack-a1") && r.channel().equals("door_contact"))
                    .map(r -> (String) r.value())
                    .findFirst().orElseThrow();
            assertTrue(state.equals("closed") || state.equals("open"), "door_contact is a state string");
            if (state.equals("open")) {
                opens++;
            }
            firstRun.add(state);
        }

        assertTrue(opens > 0, "there should be at least one door open over " + ticks + " ticks");
        assertTrue(opens < ticks * 0.05, "door opens should be rare, was " + opens + "/" + ticks);

        List<String> secondRun = new java.util.ArrayList<>();
        SimulatorEngine again = engine(config);
        for (int i = 0; i < ticks; i++) {
            secondRun.add(again.tick(i).stream()
                    .filter(r -> r.deviceId().equals("rack-a1") && r.channel().equals("door_contact"))
                    .map(r -> (String) r.value())
                    .findFirst().orElseThrow());
        }
        assertEquals(firstRun, secondRun, "door opens must be identical under a fixed SEED");
    }

    @Test
    void staysInNormalWhileAnomalyModeIsOff() {
        SimulatorEngine engine = engine(Config.defaults(1L, START_EPOCH_MILLIS));
        for (int i = 0; i < 1_000; i++) {
            engine.tick(i);
            assertTrue(engine.currentAnomaly().isEmpty(), "no anomaly at tick " + i + " with ANOMALY_MODE off");
        }
    }

    // --- Config validation (issue #71 finding B4) --------------------------------
    //
    // recoveryTicks = max(2, duration / 2). A configured cadence can only hold
    // when the next onset lands in NORMAL, i.e. every > duration + recoveryTicks.
    // INTERVAL_SECONDS must be >= 1. Anomaly bounds are enforced only when
    // ANOMALY_MODE is on (otherwise the values are inert).

    private static Config cfg(int intervalSeconds, boolean anomalyMode, int every, int duration) {
        return new Config(intervalSeconds, 42L, anomalyMode, every, duration,
                List.of("breach_high", "mains_loss"), START_EPOCH_MILLIS);
    }

    @Test
    void configAcceptsTheDocumentedDefaults() {
        assertDoesNotThrow(() -> Config.defaults(42L, START_EPOCH_MILLIS));
        assertDoesNotThrow(() -> cfg(5, true, 60, 6)); // 60 > 6 + max(2,3) = 9
    }

    @Test
    void configAcceptsAValidNonDefaultCadence() {
        assertDoesNotThrow(() -> cfg(5, true, 10, 3)); // 10 > 3 + max(2,1) = 5
    }

    @Test
    void configRejectsCadenceEqualToDurationPlusRecovery() {
        // duration 3 -> recovery max(2,1)=2 -> boundary 5; every == 5 must be rejected.
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class,
                () -> cfg(5, true, 5, 3));
        assertTrue(e.getMessage().contains("ANOMALY_EVERY_TICKS"), e.getMessage());
        // duration 6 -> recovery max(2,3)=3 -> boundary 9; every == 9 must be rejected.
        assertThrows(IllegalArgumentException.class, () -> cfg(5, true, 9, 6));
        // one past the boundary is fine.
        assertDoesNotThrow(() -> cfg(5, true, 10, 6));
    }

    @Test
    void configRejectsCadenceSmallerThanDurationPlusRecovery() {
        assertThrows(IllegalArgumentException.class, () -> cfg(5, true, 4, 3));
        assertThrows(IllegalArgumentException.class, () -> cfg(5, true, 8, 6)); // 6 + max(2,3) = 9
    }

    @Test
    void configRejectsZeroDurationWhenAnomalyModeIsOn() {
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class,
                () -> cfg(5, true, 60, 0));
        assertTrue(e.getMessage().contains("ANOMALY_DURATION_TICKS"), e.getMessage());
    }

    @Test
    void configRejectsZeroCadenceWhenAnomalyModeIsOn() {
        assertThrows(IllegalArgumentException.class, () -> cfg(5, true, 0, 6));
    }

    @Test
    void configRejectsZeroInterval() {
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class,
                () -> cfg(0, false, 60, 6));
        assertTrue(e.getMessage().contains("INTERVAL_SECONDS"), e.getMessage());
    }

    @Test
    void configRejectsNegativeInterval() {
        assertThrows(IllegalArgumentException.class, () -> cfg(-5, false, 60, 6));
    }

    @Test
    void anomalyBoundsAreNotCheckedAndCauseNoRuntimeFailureWhenAnomalyModeIsOff() {
        // With ANOMALY_MODE off the cadence/duration values are inert: construction
        // is allowed and the loop never divides by anomalyEveryTicks.
        Config config = assertDoesNotThrow(() -> cfg(5, false, 0, 0));
        SimulatorEngine engine = engine(config);
        for (int t = 0; t < 300; t++) {
            final long tick = t;
            List<Reading> readings = assertDoesNotThrow(() -> engine.tick(tick)); // no ArithmeticException
            assertFalse(readings.isEmpty());
            assertTrue(engine.currentAnomaly().isEmpty());
        }
    }

    /** One anomaly scenario at the documented default cadence (onset at tick 60). */
    private static Config anomalyConfig(long seed, String scenario) {
        return new Config(5, seed, true, 60, 6, List.of(scenario), START_EPOCH_MILLIS);
    }

    @Test
    void breachAnomalyEntersTheBreachRangeThenRecovers() {
        // Default cadence: onset tick 60; ACTIVE 60..65; RECOVERY 66..68; NORMAL from 69;
        // next onset would be tick 120, so ticks 0..110 cover exactly one cycle.
        SimulatorEngine engine = engine(anomalyConfig(21L, "breach_high"));

        List<List<Reading>> perTick = new java.util.ArrayList<>();
        List<String> phasePerTick = new java.util.ArrayList<>();
        String targetDevice = null;
        String targetChannel = null;

        for (int tick = 0; tick <= 110; tick++) {
            perTick.add(engine.tick(tick));
            Optional<AnomalyInfo> anomaly = engine.currentAnomaly();
            phasePerTick.add(anomaly.map(AnomalyInfo::phase).orElse("NORMAL"));
            if (tick == 60) {
                AnomalyInfo info = anomaly.orElseThrow();
                assertEquals("ACTIVE", info.phase());
                assertEquals("breach_high", info.scenario());
                targetDevice = info.deviceId();
                targetChannel = info.channel();
            }
        }

        double normalMax = Double.NEGATIVE_INFINITY;
        for (int tick = 0; tick < 60; tick++) {
            normalMax = Math.max(normalMax, valueOf(perTick.get(tick), targetDevice, targetChannel));
        }

        boolean sawActive = false;
        boolean recoveredToNormal = false;
        for (int tick = 60; tick <= 110; tick++) {
            double value = valueOf(perTick.get(tick), targetDevice, targetChannel);
            if ("ACTIVE".equals(phasePerTick.get(tick))) {
                sawActive = true;
                assertTrue(value > normalMax * 1.25,
                        targetDevice + "/" + targetChannel + " breached to " + value
                                + " (normal peak " + normalMax + ")");
            } else if (tick >= 75) {
                recoveredToNormal = true;
                assertTrue(value <= normalMax * 1.15,
                        targetDevice + "/" + targetChannel + " back to " + value
                                + " after recovery (normal peak " + normalMax + ")");
            }
        }

        assertTrue(sawActive, "an ACTIVE breach window must occur");
        assertTrue(recoveredToNormal, "the channel must return to its normal band");
        assertTrue(engine.currentAnomaly().isEmpty(), "the state machine returns to NORMAL");
    }

    /**
     * A breach is a value driven far past the channel's normal ceiling; this
     * margin is comfortably larger than any bounded-noise excursion yet smaller
     * than the smallest breach delta for the unit family.
     */
    private static double breachMargin(String unit) {
        return switch (unit) {
            case "°C" -> 5.0;
            case "rpm" -> 500.0;
            case "W" -> 300.0;
            case "%" -> 10.0;
            case "A" -> 2.5;
            default -> Double.POSITIVE_INFINITY; // e.g. "V" is never a breach_high target
        };
    }

    @Test
    void anomalyCadenceAndDurationFollowTheSuppliedConfig() {
        // Non-default values on purpose: 60 (cadence) and 6/12 (duration) must not
        // be hardcoded. every=10 > duration + recovery, so every onset lands in a
        // NORMAL phase and the observable cadence is exactly `every`.
        int every = 10;
        int duration = 3;
        int ticks = 45;
        SimulatorEngine engine = engine(new Config(5, 77L, true, every, duration,
                List.of("breach_high"), START_EPOCH_MILLIS));

        List<List<Reading>> perTick = new java.util.ArrayList<>();
        for (int t = 0; t < ticks; t++) {
            perTick.add(engine.tick(t));
        }

        // Pre-onset ticks (0 .. every-1) are anomaly-free: per-channel normal ceiling.
        Map<String, Double> normalMax = new java.util.HashMap<>();
        for (int t = 0; t < every; t++) {
            for (Reading r : perTick.get(t)) {
                if (r.value() instanceof Number n) {
                    normalMax.merge(r.deviceId() + "/" + r.channel(), n.doubleValue(), Math::max);
                }
            }
        }

        // Ticks where SOME channel is driven far past its normal ceiling.
        java.util.TreeSet<Long> breachedTicks = new java.util.TreeSet<>();
        for (int t = 0; t < ticks; t++) {
            for (Reading r : perTick.get(t)) {
                if (r.value() instanceof Number n
                        && n.doubleValue() > normalMax.get(r.deviceId() + "/" + r.channel())
                                + breachMargin(r.unit())) {
                    breachedTicks.add((long) t);
                    break;
                }
            }
        }

        // Expected windows derived ONLY from `every` and `duration`.
        java.util.TreeSet<Long> expected = new java.util.TreeSet<>();
        for (long onset = every; onset < ticks; onset += every) {
            for (long d = 0; d < duration && onset + d < ticks; d++) {
                expected.add(onset + d);
            }
        }

        assertEquals(expected, breachedTicks,
                "breach windows must be [k*every, k*every+duration) for the supplied config");
        // The four observable properties the equality enforces, spelled out:
        assertTrue(breachedTicks.stream().noneMatch(t -> t < every),
                "no breach before the first configured onset (tick " + every + ")");
        assertTrue(breachedTicks.contains((long) every),
                "breach starts at the configured cadence");
        for (long d = 0; d < duration; d++) {
            assertTrue(breachedTicks.contains(every + d), "breach ACTIVE at tick " + (every + d));
        }
        assertFalse(breachedTicks.contains((long) (every + duration)),
                "breach ACTIVE lasts exactly " + duration + " ticks, then recovery/normal resumes");
    }

    @Test
    void mainsLossAnomalyDischargesTheBatteryThenRecharges() {
        SimulatorEngine engine = engine(anomalyConfig(31L, "mains_loss"));

        Double prevBattery = null;
        boolean sawDischarge = false;
        boolean sawRecharge = false;
        double minVoltageDuringActive = Double.POSITIVE_INFINITY;
        double voltageAfterRestore = Double.NaN;

        for (int tick = 0; tick <= 110; tick++) {
            List<Reading> readings = engine.tick(tick);
            double battery = valueOf(readings, "ups-1", "battery_pct");
            double voltage = valueOf(readings, "ups-1", "input_voltage");
            Optional<AnomalyInfo> anomaly = engine.currentAnomaly();
            String phase = anomaly.map(AnomalyInfo::phase).orElse("NORMAL");

            if ("ACTIVE".equals(phase)) {
                minVoltageDuringActive = Math.min(minVoltageDuringActive, voltage);
                if (prevBattery != null && tick > 60) {
                    assertTrue(battery < prevBattery,
                            "battery must fall during mains loss: " + prevBattery + " -> " + battery);
                    sawDischarge = true;
                }
            } else if (tick >= 69) {
                voltageAfterRestore = voltage;
                if (prevBattery != null && prevBattery < 100.0) {
                    assertTrue(battery > prevBattery,
                            "battery must recharge after restoration: " + prevBattery + " -> " + battery);
                    sawRecharge = true;
                }
            }
            prevBattery = battery;
        }

        assertTrue(sawDischarge, "a discharge phase must occur");
        assertTrue(sawRecharge, "a recharge phase must occur");
        assertTrue(minVoltageDuringActive < 50.0,
                "input_voltage must sag during mains loss, min was " + minVoltageDuringActive);
        assertTrue(voltageAfterRestore > 200.0,
                "input_voltage must return to nominal after restoration, was " + voltageAfterRestore);
    }

    @Test
    void continuousChannelsStayWithinPhysicallySensibleBounds() {
        SimulatorEngine engine = engine(Config.defaults(7L, START_EPOCH_MILLIS));

        for (long tick = 0; tick < 5_000; tick++) {
            for (Reading r : engine.tick(tick)) {
                double[] range = BOUNDS.get(r.deviceId() + "/" + r.channel());
                if (range == null) {
                    continue; // door_contact — asserted elsewhere
                }
                double v = asDouble(r.value());
                assertTrue(v >= range[0] && v <= range[1],
                        r.deviceId() + "/" + r.channel() + " = " + v + " outside [" + range[0] + ", " + range[1] + "]");
            }
        }
    }

    @Test
    void emitsOneReadingPerRegistryChannelPerTickWithDeclaredUnit() {
        List<Device> registry = serverRoomRegistry();
        SimulatorEngine engine = new SimulatorEngine(registry, Config.defaults(42L, START_EPOCH_MILLIS));

        List<Reading> readings = engine.tick(0);

        int expectedCount = registry.stream().mapToInt(d -> d.channels().size()).sum();
        assertEquals(expectedCount, readings.size(), "one reading per registry channel");

        for (Device device : registry) {
            for (Channel channel : device.channels()) {
                List<Reading> matches = readings.stream()
                        .filter(r -> r.deviceId().equals(device.deviceId())
                                && r.channel().equals(channel.name()))
                        .toList();
                assertEquals(1, matches.size(),
                        device.deviceId() + "/" + channel.name() + " emitted exactly once");
                assertEquals(channel.unit(), matches.get(0).unit(),
                        device.deviceId() + "/" + channel.name() + " uses the registry unit");
            }
        }
    }
}
