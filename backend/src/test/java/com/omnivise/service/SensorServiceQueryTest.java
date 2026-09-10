package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.bson.Document;
import org.junit.jupiter.api.Test;

/**
 * Filter construction for {@code GET /api/sensors/latest} (issue #70).
 *
 * <p>The endpoint takes optional {@code deviceId} and {@code channel} filters.
 * These tests pin the MongoDB filter document produced for every combination so
 * the query contract is verified without a live MongoDB. Sort direction
 * ({@code timestamp} descending) is covered by
 * {@link #latestReadingsSortByTimestampDescending()}.
 */
class SensorServiceQueryTest {

    @Test
    void noFiltersProduceAnEmptyQuery() {
        assertEquals(new Document(), SensorService.buildLatestFilter(null, null));
    }

    @Test
    void deviceIdOnlyFiltersOnDeviceId() {
        assertEquals(
                new Document("deviceId", "rack-a1"),
                SensorService.buildLatestFilter("rack-a1", null));
    }

    @Test
    void channelOnlyFiltersOnChannel() {
        assertEquals(
                new Document("channel", "intake_temp"),
                SensorService.buildLatestFilter(null, "intake_temp"));
    }

    @Test
    void bothFiltersAreCombined() {
        assertEquals(
                new Document("deviceId", "rack-a1").append("channel", "intake_temp"),
                SensorService.buildLatestFilter("rack-a1", "intake_temp"));
    }

    @Test
    void blankFilterComponentsAreTreatedAsAbsent() {
        assertEquals(new Document(), SensorService.buildLatestFilter("", "   "));
        assertEquals(
                new Document("channel", "load_pct"),
                SensorService.buildLatestFilter("  ", "load_pct"));
    }

    @Test
    void latestReadingsSortByTimestampDescending() {
        assertEquals(-1, SensorService.SORT_NEWEST_FIRST.getInteger("timestamp"));
        assertTrue(
                SensorService.SORT_NEWEST_FIRST.keySet().contains("timestamp"),
                "latest readings must be ordered by the timestamp field");
    }
}
