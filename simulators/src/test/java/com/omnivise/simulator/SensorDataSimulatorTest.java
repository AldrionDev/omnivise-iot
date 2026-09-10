package com.omnivise.simulator;

import static org.junit.jupiter.api.Assertions.assertEquals;
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

    /** Mutable fake wall clock; the fake sleeper advances it. */
    private static final class FakeClock implements LongSupplier {
        private long now;

        FakeClock(long start) {
            this.now = start;
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
    void loopClampsTheWaitToZeroWhenATickOverrunsItsBoundary() {
        int interval = 1;                 // 1000 ms grid
        long workMillis = 1500L;          // every tick overruns its 1000 ms boundary
        int ticks = 10;
        long intervalMillis = interval * 1000L;

        FakeClock clock = new FakeClock(START);
        List<Long> sleeps = new ArrayList<>();
        List<Long> generatedTs = new ArrayList<>();

        Consumer<List<Reading>> sink = batch -> {
            generatedTs.add(batch.get(0).timestamp().getTime());
            clock.now += workMillis;
        };
        SensorDataSimulator.Sleeper sleeper = millis -> {
            sleeps.add(millis);
            clock.now += millis;
        };

        SensorDataSimulator.runLoop(engineFor(42L, START, interval), sink, interval, START,
                clock, sleeper, ticks);

        assertEquals(ticks, sleeps.size());
        for (long slept : sleeps) {
            assertEquals(0L, slept,
                    "under sustained overrun the wait clamps to 0, never a negative delay");
        }
        for (int k = 0; k < ticks; k++) {
            assertEquals(START + (long) k * intervalMillis, generatedTs.get(k),
                    "generated timestamps stay deterministic even when the loop cannot keep up");
        }
    }
}
