package com.omnivise.model;

import java.util.List;

/**
 * Down-sampled time-series for one device/channel over a time range, returned by
 * {@code GET /api/sensors/history} (issue #72).
 *
 * <p>{@link #unit()} is the channel's registered unit from the device registry.
 * {@link #bucket()} echoes the requested bucket label ({@code 1m} / {@code 5m} /
 * {@code 1h}). {@link #points()} is ordered ascending by bucket start and is
 * empty when the range holds no readings.
 */
public record SensorHistory(
        String deviceId,
        String channel,
        String unit,
        String bucket,
        List<Point> points
) {
    /**
     * One bucket. {@link #t()} is the bucket start as an ISO-8601 UTC string;
     * {@link #avg()}/{@link #min()}/{@link #max()} are the aggregates of the
     * readings in the bucket, or {@code null} for a non-numeric channel.
     */
    public record Point(String t, Double avg, Double min, Double max) {
    }
}
