package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Duration;
import java.util.Optional;

import org.junit.jupiter.api.Test;

/**
 * The {@link Bucket} enum is the single source of truth for the down-sampling
 * widths accepted by {@code GET /api/sensors/history} (issue #72). It maps a
 * client-facing label ({@code 1m} / {@code 5m} / {@code 1h}) to the MongoDB
 * {@code $dateTrunc} parameters and to the {@link Duration} the range/bucket
 * count guard needs.
 */
class BucketTest {

    @Test
    void labelResolvesToTheMatchingBucket() {
        assertEquals(Optional.of(Bucket.M1), Bucket.fromLabel("1m"));
        assertEquals(Optional.of(Bucket.M5), Bucket.fromLabel("5m"));
        assertEquals(Optional.of(Bucket.H1), Bucket.fromLabel("1h"));
    }

    @Test
    void anUnknownOrMissingLabelResolvesToEmpty() {
        assertTrue(Bucket.fromLabel("2m").isEmpty());
        assertTrue(Bucket.fromLabel("").isEmpty());
        assertTrue(Bucket.fromLabel(null).isEmpty());
        assertTrue(Bucket.fromLabel("1M").isEmpty(), "label match is case-sensitive");
    }

    @Test
    void oneMinuteBucketMapsToDateTruncMinuteBinSizeOne() {
        assertEquals("1m", Bucket.M1.label());
        assertEquals("minute", Bucket.M1.truncUnit());
        assertEquals(1, Bucket.M1.binSize());
        assertEquals(Duration.ofMinutes(1), Bucket.M1.duration());
    }

    @Test
    void fiveMinuteBucketMapsToDateTruncMinuteBinSizeFive() {
        assertEquals("5m", Bucket.M5.label());
        assertEquals("minute", Bucket.M5.truncUnit());
        assertEquals(5, Bucket.M5.binSize());
        assertEquals(Duration.ofMinutes(5), Bucket.M5.duration());
    }

    @Test
    void oneHourBucketMapsToDateTruncHourBinSizeOne() {
        assertEquals("1h", Bucket.H1.label());
        assertEquals("hour", Bucket.H1.truncUnit());
        assertEquals(1, Bucket.H1.binSize());
        assertEquals(Duration.ofHours(1), Bucket.H1.duration());
    }

    @Test
    void allowedLabelsListsEveryBucketInDeclaredOrder() {
        assertEquals("[1m, 5m, 1h]", Bucket.allowedLabels());
    }
}
