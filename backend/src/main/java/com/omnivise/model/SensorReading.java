package com.omnivise.model;

/**
 * A single sensor reading, keyed by {@code deviceId} + {@code channel}.
 *
 * <p>{@code value} is left as an opaque {@link Object} because a channel may be
 * numeric ({@code intake_temp}) or boolean ({@code door_contact}).
 * {@code timestamp} is an ISO-8601 UTC string; the shared
 * {@code SensorReadingMapper} normalises the stored BSON {@code Date} into that
 * form so JSON serialisation stays dependency-free.
 */
public record SensorReading(
        String deviceId,
        String channel,
        Object value,
        String unit,
        String timestamp
) {
}
