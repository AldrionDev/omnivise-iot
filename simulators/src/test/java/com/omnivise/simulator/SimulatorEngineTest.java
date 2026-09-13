package com.omnivise.simulator;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

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

    private static Config anomalyConfig(
            long seed, int every, int duration, int maxConcurrent, List<String> scenarios) {
        return new Config(5, seed, true, every, duration, maxConcurrent,
                scenarios, START_EPOCH_MILLIS);
    }

    private static Config anomalyConfig(
            long seed, int every, int duration, int recovery,
            int maxConcurrent, List<String> scenarios) {
        return new Config(5, seed, true, every, duration, recovery, maxConcurrent,
                scenarios, START_EPOCH_MILLIS);
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
            assertTrue(engine.currentAnomalies().isEmpty(),
                    "no anomaly at tick " + i + " with ANOMALY_MODE off");
        }
    }

    // --- Config validation --------------------------------------------------------

    private static Config cfg(int intervalSeconds, boolean anomalyMode, int every, int duration) {
        return new Config(intervalSeconds, 42L, anomalyMode, every, duration, 2,
                List.of("breach_high", "mains_loss"), START_EPOCH_MILLIS);
    }

    @Test
    void configAcceptsTheDocumentedDefaults() {
        assertDoesNotThrow(() -> Config.defaults(42L, START_EPOCH_MILLIS));
        assertDoesNotThrow(() -> cfg(5, true, 60, 6));
    }

    @Test
    void configAcceptsAValidNonDefaultCadence() {
        assertDoesNotThrow(() -> cfg(5, true, 10, 3));
    }

    @Test
    void omittedRecoveryDerivesTheLegacyValue() {
        Config config = cfg(5, false, 60, 6);

        assertEquals(3, config.anomalyRecoveryTicks());
        assertEquals(2, new Config(5, 42L, false, 60, 3, 1,
                List.of("breach_high"), START_EPOCH_MILLIS).anomalyRecoveryTicks());
    }

    @Test
    void explicitRecoveryIsRetained() {
        Config config = new Config(5, 42L, false, 60, 6, 7, 1,
                List.of("breach_high"), START_EPOCH_MILLIS);

        assertEquals(7, config.anomalyRecoveryTicks());
    }

    @Test
    void defaultsUseCompatibilityRecoveryAndConcurrencyOne() {
        Config defaults = Config.defaults(42L, START_EPOCH_MILLIS);

        assertEquals(3, defaults.anomalyRecoveryTicks());
        assertEquals(1, defaults.maxConcurrentAnomalies());
    }

    @Test
    void configRejectsConcurrencyOutsideTheSupportedBound() {
        assertThrows(IllegalArgumentException.class, () -> new Config(
                5, 42L, false, 4, 3, 0, List.of("breach_high"), START_EPOCH_MILLIS));
        assertThrows(IllegalArgumentException.class, () -> new Config(
                5, 42L, false, 4, 3, 3, List.of("breach_high"), START_EPOCH_MILLIS));
    }

    @Test
    void configRejectsZeroDurationEvenWhenAnomalyModeIsOff() {
        IllegalArgumentException e = assertThrows(IllegalArgumentException.class,
                () -> cfg(5, false, 60, 0));
        assertTrue(e.getMessage().contains("ANOMALY_DURATION_TICKS"), e.getMessage());
    }

    @Test
    void configRejectsZeroCadenceEvenWhenAnomalyModeIsOff() {
        assertThrows(IllegalArgumentException.class, () -> cfg(5, false, 0, 6));
    }

    @Test
    void configRejectsZeroRecoveryEvenWhenAnomalyModeIsOff() {
        assertThrows(IllegalArgumentException.class, () -> new Config(
                5, 42L, false, 60, 6, 0, 1,
                List.of("breach_high"), START_EPOCH_MILLIS));
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
    void configAcceptsCapacityEquality() {
        assertDoesNotThrow(() -> anomalyConfig(
                42L, 12, 18, 6, 2, List.of("breach_high", "mains_loss")));
    }

    @Test
    void configRejectsEnabledLifecycleOverCapacity() {
        IllegalArgumentException error = assertThrows(IllegalArgumentException.class,
                () -> anomalyConfig(42L, 12, 19, 6, 2, List.of("breach_high")));

        assertTrue(error.getMessage().contains("ANOMALY_EVERY_TICKS * MAX_CONCURRENT_ANOMALIES"));
    }

    @Test
    void capacityArithmeticWidensBeforeAdditionAndMultiplication() {
        assertDoesNotThrow(() -> anomalyConfig(
                42L, Integer.MAX_VALUE, Integer.MAX_VALUE, Integer.MAX_VALUE,
                2, List.of("breach_high")));
        assertThrows(IllegalArgumentException.class, () -> anomalyConfig(
                42L, Integer.MAX_VALUE - 1, Integer.MAX_VALUE, Integer.MAX_VALUE,
                2, List.of("breach_high")));
    }

    @Test
    void omittedRecoveryRetainsLegacyCapacitySemantics() {
        assertDoesNotThrow(() -> anomalyConfig(
                42L, 5, 6, 2, List.of("breach_high")));
        assertThrows(IllegalArgumentException.class, () -> anomalyConfig(
                42L, 4, 6, 2, List.of("breach_high")));
    }

    /** One anomaly scenario at the documented default cadence (onset at tick 60). */
    private static Config anomalyConfig(long seed, String scenario) {
        return anomalyConfig(seed, 60, 6, 2, List.of(scenario));
    }

    @Test
    void lifecycleUsesExactActiveAndRecoveryHalfOpenWindows() {
        SimulatorEngine engine = engine(anomalyConfig(12L, 10, 3, 2, List.of("breach_high")));

        for (int tick = 0; tick <= 15; tick++) {
            engine.tick(tick);
            List<AnomalyInfo> anomalies = engine.currentAnomalies();
            if (tick < 10 || tick >= 15) {
                assertTrue(anomalies.isEmpty(), "no anomaly at tick " + tick);
            } else {
                String expectedPhase = tick < 13 ? "ACTIVE" : "RECOVERY";
                assertEquals(expectedPhase, anomalies.get(0).phase(), "phase at tick " + tick);
            }
        }
    }

    @Test
    void lifecycleUsesExplicitRecoveryTicks() {
        SimulatorEngine engine = engine(anomalyConfig(
                12L, 12, 3, 7, 1, List.of("breach_high")));

        for (int tick = 0; tick <= 22; tick++) {
            engine.tick(tick);
            List<AnomalyInfo> anomalies = engine.currentAnomalies();
            if (tick < 12 || tick >= 22) {
                assertTrue(anomalies.isEmpty(), "no anomaly at tick " + tick);
            } else {
                assertEquals(tick < 15 ? "ACTIVE" : "RECOVERY",
                        anomalies.get(0).phase(), "phase at tick " + tick);
            }
        }
    }

    @Test
    void supportsTwoDisjointInstancesAndCountsRecoveryTowardTheLimit() {
        SimulatorEngine engine = engine(anomalyConfig(
                42L, 3, 3, 3, 2, List.of("breach_high", "mains_loss")));

        List<Reading> overlappingReadings = List.of();
        for (int tick = 0; tick <= 6; tick++) {
            overlappingReadings = engine.tick(tick);
        }
        assertEquals(List.of("RECOVERY", "ACTIVE"),
                engine.currentAnomalies().stream().map(AnomalyInfo::phase).toList());
        assertEquals(List.of("breach_high", "mains_loss"),
                engine.currentAnomalies().stream().map(AnomalyInfo::scenario).toList());
        assertEquals(20, overlappingReadings.size());
        assertEquals(20, overlappingReadings.stream()
                .map(reading -> reading.deviceId() + "/" + reading.channel())
                .distinct()
                .count(), "overlapping anomalies cannot duplicate emitted channels");

        engine.tick(7);
        engine.tick(8);
        engine.tick(9);

        List<AnomalyInfo> anomalies = engine.currentAnomalies();
        assertEquals(2, anomalies.size());
        assertEquals(List.of(2L, 3L), anomalies.stream().map(AnomalyInfo::id).toList(),
                "every scheduled onset is admitted at capacity equality");
        assertEquals(List.of("RECOVERY", "ACTIVE"), anomalies.stream().map(AnomalyInfo::phase).toList());
        assertEquals(List.of("mains_loss", "breach_high"),
                anomalies.stream().map(AnomalyInfo::scenario).toList());
        assertFalse(anomalies.get(0).deviceId().equals(anomalies.get(1).deviceId())
                        && anomalies.get(0).channel().equals(anomalies.get(1).channel()),
                "concurrent display targets must be disjoint");
    }

    @Test
    void releasesCompletedInstanceBeforeAdmissionOnTheSameTick() {
        SimulatorEngine engine = engine(anomalyConfig(9L, 5, 3, 1, List.of("breach_high")));

        for (int tick = 0; tick <= 10; tick++) {
            engine.tick(tick);
        }

        List<AnomalyInfo> anomalies = engine.currentAnomalies();
        assertEquals(1, anomalies.size());
        assertEquals(2L, anomalies.get(0).id());
        assertEquals("ACTIVE", anomalies.get(0).phase(),
                "the replacement starts when the previous recovery deadline is reached");
    }

    @Test
    void concurrentBreachesSelectDeterministicAlternativeDisjointTargets() {
        Config config = anomalyConfig(17L, 2, 2, 2, 2, List.of("breach_high"));
        SimulatorEngine first = engine(config);
        SimulatorEngine second = engine(config);

        first.tick(0);
        second.tick(0);
        first.tick(1);
        second.tick(1);
        first.tick(2);
        second.tick(2);
        first.tick(3);
        second.tick(3);
        List<Reading> firstReadings = first.tick(4);
        List<Reading> secondReadings = second.tick(4);

        List<AnomalyInfo> firstSnapshot = first.currentAnomalies();
        assertEquals(firstSnapshot, second.currentAnomalies());
        assertEquals(firstReadings, secondReadings);
        assertEquals(2, firstSnapshot.size());
        assertFalse(firstSnapshot.get(0).deviceId().equals(firstSnapshot.get(1).deviceId())
                        && firstSnapshot.get(0).channel().equals(firstSnapshot.get(1).channel()),
                "alternative target selection must avoid the reserved breach footprint");
    }

    @Test
    void breachHighIsNotAdmittedWithoutACanonicalWarningTarget() {
        List<Device> registry = List.of(new Device("ups-1", "ups", List.of(
                new Channel("battery_pct", "%"),
                new Channel("input_voltage", "V"))));
        SimulatorEngine engine = new SimulatorEngine(registry,
                anomalyConfig(17L, 2, 2, 2, 2, List.of("breach_high")));

        for (int tick = 0; tick < 10; tick++) {
            List<Reading> readings = engine.tick(tick);
            assertEquals(2, readings.size());
            assertTrue(engine.currentAnomalies().isEmpty());
        }
    }

    @Test
    void currentAnomaliesIsImmutableAndDoesNotChangeAfterLaterTicks() {
        SimulatorEngine engine = engine(anomalyConfig(
                22L, 2, 3, 1, 2, List.of("breach_high")));
        engine.tick(0);
        engine.tick(1);
        engine.tick(2);

        List<AnomalyInfo> snapshot = engine.currentAnomalies();
        assertThrows(UnsupportedOperationException.class, snapshot::clear);

        engine.tick(3);
        engine.tick(4);
        assertEquals(1, snapshot.size());
        assertEquals("ACTIVE", snapshot.get(0).phase());
        assertEquals(List.of(1L, 2L),
                engine.currentAnomalies().stream().map(AnomalyInfo::id).toList());
    }

    @Test
    void identicalInputsProduceIdenticalConcurrentSnapshotsAndReadings() {
        Config config = anomalyConfig(
                81L, 2, 3, 1, 2, List.of("breach_high", "mains_loss"));
        SimulatorEngine first = engine(config);
        SimulatorEngine second = engine(config);

        for (int tick = 0; tick < 50; tick++) {
            assertEquals(first.tick(tick), second.tick(tick), "readings at tick " + tick);
            assertEquals(first.currentAnomalies(), second.currentAnomalies(),
                    "anomaly snapshot at tick " + tick);
        }
    }

    @Test
    void maxConcurrencyOnePreservesTheLegacyGoldenSequence() {
        SimulatorEngine engine = engine(anomalyConfig(
                42L, 10, 3, 1, List.of("breach_high", "mains_loss")));
        List<Long> onsetTicks = new ArrayList<>();
        List<String> targets = new ArrayList<>();
        List<Object> selectedValues = new ArrayList<>();
        List<Long> timestamps = new ArrayList<>();
        long lastObservedId = 0;

        List<String> expectedReadingOrder = List.of(
                "rack-a1/intake_temp", "rack-a1/exhaust_temp", "rack-a1/humidity",
                "rack-a1/power_draw", "rack-a1/fan_rpm", "rack-a1/door_contact",
                "rack-a2/intake_temp", "rack-a2/exhaust_temp", "rack-a2/humidity",
                "rack-a2/power_draw", "rack-a2/fan_rpm", "rack-a2/door_contact",
                "ups-1/load_pct", "ups-1/battery_pct", "ups-1/input_voltage",
                "pdu-a1/power_draw", "pdu-a1/current",
                "crac-1/supply_temp", "crac-1/return_temp", "crac-1/fan_rpm");

        for (int tick = 0; tick <= 30; tick++) {
            List<Reading> readings = engine.tick(tick);
            if (tick == 0) {
                assertEquals(expectedReadingOrder, readings.stream()
                        .map(reading -> reading.deviceId() + "/" + reading.channel())
                        .toList());
                assertEquals(20.4, valueOf(readings, "rack-a1", "intake_temp"));
            }

            List<AnomalyInfo> anomalies = engine.currentAnomalies();
            if (!anomalies.isEmpty() && anomalies.get(0).id() != lastObservedId) {
                AnomalyInfo anomaly = anomalies.get(0);
                lastObservedId = anomaly.id();
                onsetTicks.add((long) tick);
                targets.add(anomaly.scenario() + ":" + anomaly.deviceId() + "/" + anomaly.channel());
                Reading selected = readings.stream()
                        .filter(reading -> reading.deviceId().equals(anomaly.deviceId())
                                && reading.channel().equals(anomaly.channel()))
                        .findFirst()
                        .orElseThrow();
                selectedValues.add(selected.value());
                timestamps.add(selected.timestamp().getTime());
            }
        }

        assertEquals(List.of(10L, 20L, 30L), onsetTicks);
        assertEquals(List.of(
                "breach_high:rack-a1/intake_temp",
                "mains_loss:ups-1/battery_pct",
                "breach_high:crac-1/return_temp"), targets);
        assertEquals(List.of(35.2, 97.5, 39.3), selectedValues,
                "selected values also guard anomaly target RNG draw count");
        assertEquals(List.of(
                START_EPOCH_MILLIS + 50_000L,
                START_EPOCH_MILLIS + 100_000L,
                START_EPOCH_MILLIS + 150_000L), timestamps);
    }

    @Test
    void mainsLossReservesAndMutatesTheCompleteUpsFootprintOnlyOncePerTick() {
        List<Device> registry = new ArrayList<>(serverRoomRegistry());
        registry.add(new Device("ups-2", "ups", List.of(
                new Channel("load_pct", "%"),
                new Channel("battery_pct", "%"),
                new Channel("input_voltage", "V"))));
        SimulatorEngine engine = new SimulatorEngine(registry,
                anomalyConfig(31L, 2, 2, 2, 2, List.of("mains_loss")));

        engine.tick(0);
        engine.tick(1);
        for (int tick = 2; tick <= 5; tick++) {
            List<Reading> readings = engine.tick(tick);
            assertEquals(1, engine.currentAnomalies().size(),
                    "the complete UPS footprint remains reserved at tick " + tick);
            assertEquals(1L, engine.currentAnomalies().get(0).id(),
                    "colliding scheduled starts do not consume IDs");
            if (tick <= 3) {
                double expectedBattery = 100.0 - (tick - 1) * 2.5;
                for (String ups : List.of("ups-1", "ups-2")) {
                    assertEquals(expectedBattery, valueOf(readings, ups, "battery_pct"));
                    assertTrue(valueOf(readings, ups, "input_voltage") < 10.0,
                            ups + " input voltage is affected by the same logical anomaly");
                }
            }
        }

        List<Reading> replacementTick = engine.tick(6);
        assertEquals(2L, engine.currentAnomalies().get(0).id(),
                "release occurs before the colliding scenario is admitted on the deadline tick");
        assertEquals(94.5, valueOf(replacementTick, "ups-1", "battery_pct"),
                "one logical mains loss applies one battery mutation per channel/tick");
        assertEquals(94.5, valueOf(replacementTick, "ups-2", "battery_pct"));
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
            List<AnomalyInfo> anomalies = engine.currentAnomalies();
            phasePerTick.add(anomalies.isEmpty() ? "NORMAL" : anomalies.get(0).phase());
            if (tick == 60) {
                AnomalyInfo info = anomalies.get(0);
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
        assertTrue(engine.currentAnomalies().isEmpty(), "the state machine returns to NORMAL");
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
        SimulatorEngine engine = engine(new Config(5, 77L, true, every, duration, 2,
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
    void breachHighTargetsOnlyCanonicalWarningAlertChannels() {
        SimulatorEngine engine = engine(new Config(
                5, 42L, true, 10, 3, 2,
                List.of("breach_high"), START_EPOCH_MILLIS));

        java.util.Set<String> allowed = java.util.Set.of(
                "rack-a1/intake_temp",
                "rack-a1/humidity",
                "rack-a2/intake_temp",
                "rack-a2/humidity",
                "crac-1/return_temp");

        java.util.Set<String> observed = new java.util.HashSet<>();

        for (int tick = 0; tick <= 1_000; tick++) {
            engine.tick(tick);
            List<AnomalyInfo> anomalies = engine.currentAnomalies();

            for (AnomalyInfo anomaly : anomalies) {
                if ("ACTIVE".equals(anomaly.phase())) {
                    String target = anomaly.deviceId() + "/" + anomaly.channel();
                    assertTrue(allowed.contains(target),
                            "breach_high selected a channel without a canonical warning alert rule: " + target);
                    observed.add(target);
                }
            }
        }

        assertEquals(allowed, observed,
                "deterministic breach_high selection should exercise every canonical warning alert target");
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
            List<AnomalyInfo> anomalies = engine.currentAnomalies();
            String phase = anomalies.isEmpty() ? "NORMAL" : anomalies.get(0).phase();

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
