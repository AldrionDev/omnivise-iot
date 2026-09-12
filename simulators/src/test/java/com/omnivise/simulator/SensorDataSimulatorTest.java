package com.omnivise.simulator;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;
import java.util.function.LongSupplier;

import org.bson.Document;
import org.junit.jupiter.api.Test;

import com.omnivise.simulator.SimulatorEngine.Channel;
import com.omnivise.simulator.SimulatorEngine.Device;
import com.omnivise.simulator.SimulatorEngine.Reading;

/**
 * Tests the pure, deterministic parts of the I/O shell: {@code devices}-document
 * parsing, seed resolution, and the absolute-schedule tick loop (exercised
 * through the {@code clock}/{@code sleeper} seams, with no real waits).
 */
class SensorDataSimulatorTest {

    private static final long START = 1_000_000L;

    @Test
    void databaseNameDefaultsOnlyWhenMissing() {
        assertEquals("omnivise_iot", SensorDataSimulator.resolveDatabaseName(null));
        assertEquals("omnivise_iot_test", SensorDataSimulator.resolveDatabaseName("omnivise_iot_test"));
    }

    @Test
    void databaseNameRejectsBlankValues() {
        assertThrows(IllegalArgumentException.class,
                () -> SensorDataSimulator.resolveDatabaseName(""));
        assertThrows(IllegalArgumentException.class,
                () -> SensorDataSimulator.resolveDatabaseName("   "));
    }

    /** Mutable fake wall clock; the fake sleeper advances it. */
    private static final class FakeClock implements LongSupplier {
        private long now;

        FakeClock(long start) {
            this.now = start;
        }

        void advance(long millis) {
            now += millis;
        }

        @Override
        public long getAsLong() {
            return now;
        }
    }

    /** A minimal engine whose interval matches the loop's, so the two grids line up. */
    private static SimulatorEngine engineFor(long seed, long startMillis, int intervalSeconds) {
        List<Device> registry = List.of(new Device("rack-a1", "rack", List.of(
                new Channel("intake_temp", "°C"),
                new Channel("power_draw", "W"))));
        return new SimulatorEngine(registry, new SimulatorEngine.Config(
                intervalSeconds, seed, false, 60, 6,
                List.of("breach_high", "mains_loss"), startMillis));
    }

    @Test
    void parseDevicesReadsDeviceIdKindAndChannelsWithTheirUnits() {
        Document rack = new Document("deviceId", "rack-a1")
                .append("name", "Rack A1")
                .append("kind", "rack")
                .append("location", "Server Room / Rack A1")
                .append("channels", List.of(
                        new Document("channel", "intake_temp").append("unit", "°C"),
                        new Document("channel", "power_draw").append("unit", "W")));
        Document ups = new Document("deviceId", "ups-1")
                .append("kind", "ups")
                .append("channels", List.of(
                        new Document("channel", "battery_pct").append("unit", "%")));

        List<Device> devices = SensorDataSimulator.parseDevices(List.of(rack, ups));

        assertEquals(2, devices.size());

        Device parsedRack = devices.get(0);
        assertEquals("rack-a1", parsedRack.deviceId());
        assertEquals("rack", parsedRack.kind());
        assertEquals(List.of("intake_temp", "power_draw"),
                parsedRack.channels().stream().map(Channel::name).toList());
        assertEquals(List.of("°C", "W"),
                parsedRack.channels().stream().map(Channel::unit).toList());

        assertEquals("ups-1", devices.get(1).deviceId());
        assertEquals("ups", devices.get(1).kind());
        assertEquals("battery_pct", devices.get(1).channels().get(0).name());
        assertEquals("%", devices.get(1).channels().get(0).unit());
    }

    @Test
    void parseDevicesToleratesADeviceWithNoChannels() {
        Document sparse = new Document("deviceId", "misc-1").append("kind", "misc");

        List<Device> devices = SensorDataSimulator.parseDevices(List.of(sparse));

        assertEquals(1, devices.size());
        assertEquals(List.of(), devices.get(0).channels());
    }

    @Test
    void deviceNaturalOrderDoesNotAffectGeneratedSequence() {
        Document rackA = new Document("deviceId", "rack-a1")
                .append("kind", "rack")
                .append("channels", List.of(
                        new Document("channel", "intake_temp").append("unit", "°C"),
                        new Document("channel", "power_draw").append("unit", "W")));
        Document rackB = new Document("deviceId", "rack-b1")
                .append("kind", "rack")
                .append("channels", List.of(
                        new Document("channel", "intake_temp").append("unit", "°C"),
                        new Document("channel", "power_draw").append("unit", "W")));

        List<Device> firstRegistry = SensorDataSimulator.parseDevices(List.of(rackA, rackB));
        List<Device> reversedRegistry = SensorDataSimulator.parseDevices(List.of(rackB, rackA));
        SimulatorEngine.Config config = new SimulatorEngine.Config(
                5, 42L, false, 60, 6,
                List.of("breach_high", "mains_loss"), START);

        List<Reading> first = readings(new SimulatorEngine(firstRegistry, config), 8);
        List<Reading> reversed = readings(new SimulatorEngine(reversedRegistry, config), 8);

        assertEquals(List.of("rack-a1", "rack-b1"), firstRegistry.stream().map(Device::deviceId).toList());
        assertEquals(first, reversed,
                "Mongo natural order must not affect emitted ordering, values, or timestamps");
    }

    @Test
    void seedDefaultsTo42WhenUnsetOrBlank() {
        assertEquals(42L, SensorDataSimulator.resolveSeed(null), "unset SEED -> 42");
        assertEquals(42L, SensorDataSimulator.resolveSeed(""), "empty SEED -> 42");
        assertEquals(42L, SensorDataSimulator.resolveSeed("   "), "blank SEED -> 42");
    }

    @Test
    void seedIsTakenFromTheEnvironmentWhenProvided() {
        assertEquals(7L, SensorDataSimulator.resolveSeed("7"));
        assertEquals(-3L, SensorDataSimulator.resolveSeed(" -3 "));
        assertEquals(20260910L, SensorDataSimulator.resolveSeed("20260910"));
    }

    @Test
    void fixedStartTimeOverridesDifferentWallClockLaunchTimes() {
        String fixedStart = "2026-09-10T00:00:00Z";
        long firstStart = SensorDataSimulator.resolveStartMillis(fixedStart, 100L);
        long secondStart = SensorDataSimulator.resolveStartMillis(fixedStart, 900L);

        assertEquals(firstStart, secondStart);
        assertEquals(readings(engineFor(42L, firstStart, 5), 8),
                readings(engineFor(42L, secondStart, 5), 8));
        assertEquals(1_000L, SensorDataSimulator.resolveStartMillis(null, 1_000L));
        assertEquals(1_000L, SensorDataSimulator.resolveStartMillis("  ", 1_000L));
    }

    @Test
    void invalidFixedStartTimeIsRejected() {
        IllegalArgumentException error = org.junit.jupiter.api.Assertions.assertThrows(
                IllegalArgumentException.class,
                () -> SensorDataSimulator.resolveStartMillis("not-an-instant", START));

        assertTrue(error.getMessage().contains("START_TIME"));
    }

    @Test
    void sameSeedAndFixedStartProduceTheSameSequence() {
        long start = SensorDataSimulator.resolveStartMillis("2026-09-10T00:00:00Z", 10L);

        List<Reading> first = readings(engineFor(42L, start, 5), 8);
        List<Reading> second = readings(engineFor(42L, start, 5), 8);

        assertEquals(first, second);
    }

    @Test
    void writeFailureStillWaitsUntilTheNextAbsoluteTick() {
        int interval = 1;
        FakeClock clock = new FakeClock(START);
        List<Long> sleeps = new ArrayList<>();
        List<Long> timestamps = new ArrayList<>();

        SensorDataSimulator.runLoop(engineFor(42L, START, interval), batch -> {
            timestamps.add(batch.get(0).timestamp().getTime());
            throw new IllegalStateException("simulated Mongo outage");
        }, interval, START, clock, millis -> {
            sleeps.add(millis);
            clock.now += millis;
        }, 1);

        assertEquals(List.of(1_000L), sleeps);
        assertEquals(List.of(START), timestamps);
    }

    @Test
    void repeatedWriteFailuresRemainPacedAndRecoveryUsesTheNormalCadence() {
        int interval = 1;
        int ticks = 5;
        FakeClock clock = new FakeClock(START);
        List<Long> sleeps = new ArrayList<>();
        List<Long> timestamps = new ArrayList<>();

        SensorDataSimulator.runLoop(engineFor(42L, START, interval), batch -> {
            timestamps.add(batch.get(0).timestamp().getTime());
            if (timestamps.size() <= 3) {
                throw new IllegalStateException("simulated Mongo outage");
            }
        }, interval, START, clock, millis -> {
            sleeps.add(millis);
            clock.now += millis;
        }, ticks);

        assertEquals(List.of(1_000L, 1_000L, 1_000L, 1_000L, 1_000L), sleeps);
        for (int tick = 0; tick < ticks; tick++) {
            assertEquals(START + tick * 1_000L, timestamps.get(tick));
        }
    }

    @Test
    void pastSimulationStartDoesNotAffectRuntimePacing() {
        int interval = 1;
        FakeClock clock = new FakeClock(START);
        List<Long> emissionTimes = new ArrayList<>();
        List<Long> sleeps = new ArrayList<>();

        SensorDataSimulator.runLoop(engineFor(42L, START - 1_000_000L, interval), batch -> {
            emissionTimes.add(clock.now);
        }, interval, START - 1_000_000L, clock, millis -> {
            sleeps.add(millis);
            clock.advance(millis);
        }, 3);

        assertEquals(List.of(START, START + 1_000L, START + 2_000L), emissionTimes);
        assertEquals(List.of(1_000L, 1_000L, 1_000L), sleeps);
    }

    @Test
    void futureSimulationStartDoesNotDelayTheFirstRuntimeTick() {
        int interval = 1;
        long simulationStart = START + 1_000_000L;
        FakeClock clock = new FakeClock(START);
        List<Long> emissionTimes = new ArrayList<>();
        List<Long> timestamps = new ArrayList<>();
        List<Long> sleeps = new ArrayList<>();

        SensorDataSimulator.runLoop(engineFor(42L, simulationStart, interval), batch -> {
            emissionTimes.add(clock.now);
            timestamps.add(batch.get(0).timestamp().getTime());
        }, interval, simulationStart, clock, millis -> {
            sleeps.add(millis);
            clock.advance(millis);
        }, 1);

        assertEquals(List.of(START), emissionTimes);
        assertEquals(List.of(simulationStart), timestamps);
        assertEquals(List.of(1_000L), sleeps);
    }

    @Test
    void loopKeepsRealExecutionOnTheTickGridSoProcessingTimeDoesNotAccumulate() {
        int interval = 5;                 // 5000 ms grid
        long workMillis = 137L;           // per-tick processing cost (insert + logging)
        int ticks = 25;
        long intervalMillis = interval * 1000L;

        FakeClock clock = new FakeClock(START);
        List<Long> sleeps = new ArrayList<>();
        List<long[]> emitted = new ArrayList<>(); // [generatedTimestamp, realTimeAtEmit]

        Consumer<List<Reading>> sink = batch -> {
            emitted.add(new long[] {batch.get(0).timestamp().getTime(), clock.now});
            clock.now += workMillis;
        };
        SensorDataSimulator.Sleeper sleeper = millis -> {
            sleeps.add(millis);
            clock.now += millis;
        };

        SensorDataSimulator.runLoop(engineFor(42L, START, interval), sink, interval, START,
                clock, sleeper, ticks);

        assertEquals(ticks, emitted.size());
        for (int k = 0; k < ticks; k++) {
            assertEquals(START + (long) k * intervalMillis, emitted.get(k)[0],
                    "generated timestamp for tick " + k + " stays on the deterministic grid");
            long drift = emitted.get(k)[1] - emitted.get(k)[0];
            assertTrue(drift >= 0 && drift <= workMillis,
                    "tick " + k + " real emit time is " + drift + " ms past its timestamp — "
                            + "processing time must not accumulate into drift");
        }
        for (long slept : sleeps) {
            assertEquals(intervalMillis - workMillis, slept,
                    "the loop waits only until the next absolute grid instant, not a fixed interval");
        }
    }

    @Test
    void loopReanchorsAfterATickOverrunsItsBoundaryInsteadOfCatchingUp() {
        int interval = 1;                 // 1000 ms grid
        long workMillis = 3500L;          // one write spans multiple 1000 ms intervals
        int ticks = 10;
        long intervalMillis = interval * 1000L;

        FakeClock clock = new FakeClock(START);
        List<Long> sleeps = new ArrayList<>();
        List<Long> generatedTs = new ArrayList<>();
        List<Long> emissionTimes = new ArrayList<>();

        Consumer<List<Reading>> sink = batch -> {
            generatedTs.add(batch.get(0).timestamp().getTime());
            emissionTimes.add(clock.now);
            clock.advance(workMillis);
            if (emissionTimes.size() == 1) {
                throw new IllegalStateException("simulated blocking Mongo outage");
            }
        };
        SensorDataSimulator.Sleeper sleeper = millis -> {
            sleeps.add(millis);
            clock.advance(millis);
        };

        SensorDataSimulator.runLoop(engineFor(42L, START, interval), sink, interval, START,
                clock, sleeper, ticks);

        assertEquals(ticks, sleeps.size());
        for (long slept : sleeps) {
            assertEquals(intervalMillis, slept,
                    "an overrun must re-anchor one full interval after the current runtime time");
        }
        for (int k = 0; k < ticks; k++) {
            assertEquals(START + (long) k * intervalMillis, generatedTs.get(k),
                    "generated timestamps stay deterministic even when the loop cannot keep up");
        }
        for (int k = 1; k < ticks; k++) {
            assertEquals(workMillis + intervalMillis, emissionTimes.get(k) - emissionTimes.get(k - 1),
                    "overruns must not cause immediate catch-up ticks");
        }
    }

    private static List<Reading> readings(SimulatorEngine engine, int ticks) {
        List<Reading> readings = new ArrayList<>();
        for (int tick = 0; tick < ticks; tick++) {
            readings.addAll(engine.tick(tick));
        }
        return readings;
    }
}
