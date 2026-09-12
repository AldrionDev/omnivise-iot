package com.omnivise.service;

import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.format.DateTimeParseException;

/**
 * A validated, normalised {@code GET /api/sensors/history} query (issue #72).
 *
 * <p>{@link #parse} is the single place every request rule lives. It never
 * throws: the outcome is a {@link Valid} carrying this immutable value object,
 * or an {@link Invalid} carrying the structured {@code {error, field, message}}
 * body the endpoint returns with {@code 400}. Validation is fail-fast — only the
 * first problem found is reported.
 *
 * <p>Rule order: required params, then {@code from}/{@code to} as ISO-8601
 * timestamps with a zone offset, then the {@code bucket} label, then a strictly
 * increasing range, then the approved maximum bucket count (measured against the
 * aligned {@code $dateTrunc} bucket count, see
 * {@link #maxAlignedBucketCount}), then existence of the device and channel in
 * the registry (which also resolves {@link #unit()}).
 */
public final class SensorHistoryRequest {

    /** Outcome of {@link SensorHistoryRequest#parse}. */
    public sealed interface Result permits Valid, Invalid {
    }

    /** A well-formed request. */
    public record Valid(SensorHistoryRequest request) implements Result {
    }

    /**
     * A rejected request. The three fields are the {@code 400} response body:
     * {@code error} is always the constant {@value #ERROR_CODE} (the approved
     * discriminator for a request-validation failure), {@code field} names the
     * offending query parameter (one of {@code deviceId}, {@code channel},
     * {@code from}, {@code to}, {@code bucket}) or {@code "range"}, and
     * {@code message} is a human-readable reason that leaks no internal detail.
     */
    public record Invalid(String error, String field, String message) implements Result {
    }

    /** The single {@code error} value for every {@link Invalid} outcome. */
    static final String ERROR_CODE = "invalid_request";

    private final String deviceId;
    private final String channel;
    private final String unit;
    private final Instant from;
    private final Instant to;
    private final Bucket bucket;

    private SensorHistoryRequest(
            String deviceId, String channel, String unit, Instant from, Instant to, Bucket bucket) {
        this.deviceId = deviceId;
        this.channel = channel;
        this.unit = unit;
        this.from = from;
        this.to = to;
        this.bucket = bucket;
    }

    /**
     * Validates raw query-parameter values.
     *
     * @param deviceId       raw {@code deviceId} value, may be {@code null}
     * @param channel        raw {@code channel} value, may be {@code null}
     * @param from           raw {@code from} value, may be {@code null}
     * @param to             raw {@code to} value, may be {@code null}
     * @param bucket         raw {@code bucket} value, may be {@code null}
     * @param devices        registry used to resolve the unit and reject unknown
     *                       device/channel
     * @param maxBucketCount approved upper bound on the number of aligned
     *                       {@code $dateTrunc} buckets the range may span
     * @return {@link Valid} or {@link Invalid}, never {@code null}, never throws
     */
    public static Result parse(
            String deviceId,
            String channel,
            String from,
            String to,
            String bucket,
            DeviceService devices,
            int maxBucketCount) {

        if (isBlank(deviceId)) {
            return missing("deviceId");
        }
        if (isBlank(channel)) {
            return missing("channel");
        }
        if (isBlank(from)) {
            return missing("from");
        }
        if (isBlank(to)) {
            return missing("to");
        }
        if (isBlank(bucket)) {
            return missing("bucket");
        }

        Instant fromInstant = parseTimestamp(from);
        if (fromInstant == null) {
            return invalidTimestamp("from");
        }
        Instant toInstant = parseTimestamp(to);
        if (toInstant == null) {
            return invalidTimestamp("to");
        }

        Bucket resolvedBucket = Bucket.fromLabel(bucket).orElse(null);
        if (resolvedBucket == null) {
            return invalid("bucket", "bucket must be one of " + Bucket.allowedLabels());
        }

        if (!fromInstant.isBefore(toInstant)) {
            return invalid("range", "from must be strictly before to");
        }

        long maxBuckets = maxAlignedBucketCount(fromInstant, toInstant, resolvedBucket);
        if (maxBuckets > maxBucketCount) {
            return invalid(
                    "range",
                    "the requested range spans up to " + maxBuckets + " " + resolvedBucket.label()
                            + " buckets, the maximum is " + maxBucketCount
                            + "; use a wider bucket or a shorter range");
        }

        if (devices.getDevice(deviceId).isEmpty()) {
            return invalid("deviceId", "unknown device");
        }
        String resolvedUnit = devices.findChannelUnit(deviceId, channel).orElse(null);
        if (resolvedUnit == null) {
            return invalid("channel", "unknown channel for this device");
        }

        return new Valid(new SensorHistoryRequest(
                deviceId, channel, resolvedUnit, fromInstant, toInstant, resolvedBucket));
    }

    public String deviceId() {
        return deviceId;
    }

    public String channel() {
        return channel;
    }

    /** Unit resolved from the device registry, for the response body. */
    public String unit() {
        return unit;
    }

    public Instant from() {
        return from;
    }

    public Instant to() {
        return to;
    }

    public Bucket bucket() {
        return bucket;
    }

    private static Invalid invalid(String field, String message) {
        return new Invalid(ERROR_CODE, field, message);
    }

    private static Invalid missing(String field) {
        return invalid(field, field + " is required");
    }

    private static Invalid invalidTimestamp(String field) {
        return invalid(
                field,
                field + " must be an ISO-8601 timestamp with a zone offset, e.g. 2026-09-10T08:00:00Z");
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    /**
     * Parses an ISO-8601 timestamp that carries a zone offset and is
     * representable as a BSON {@code Date} (signed 64-bit epoch milliseconds),
     * or returns {@code null}. {@link OffsetDateTime} accepts years far beyond
     * that range; such an instant would otherwise fail later in
     * {@link Instant#toEpochMilli()} / {@code Date.from(...)}.
     */
    private static Instant parseTimestamp(String value) {
        try {
            Instant instant = OffsetDateTime.parse(value).toInstant();
            instant.toEpochMilli(); // throws ArithmeticException outside the BSON Date range
            return instant;
        } catch (DateTimeParseException | ArithmeticException e) {
            return null;
        }
    }

    /**
     * The largest number of {@code $dateTrunc} buckets the query can return for
     * this range — the count guarded against {@code maxBucketCount}.
     *
     * <p>It is <em>not</em> {@code ceil((to - from) / width)}: {@code $dateTrunc}
     * bins are aligned to whole multiples of the bucket width from the Unix epoch
     * (its {@code 2000-01-01} reference is itself epoch-aligned for the minute and
     * hour widths used here), so an unaligned range crosses one more boundary than
     * its length alone implies. Matched timestamps are {@code [from, to)}, so the
     * distinct bucket starts run from {@code floor(from / width)} to
     * {@code floor((to - 1ms) / width)} inclusive. Callers must have already
     * rejected {@code from >= to}, so the result is always {@code >= 1}. The
     * actual response may hold fewer points when data is sparse.
     */
    private static long maxAlignedBucketCount(Instant from, Instant to, Bucket bucket) {
        long width = bucket.duration().toMillis();
        long firstBin = Math.floorDiv(from.toEpochMilli(), width);
        long lastBin = Math.floorDiv(to.toEpochMilli() - 1, width);
        return lastBin - firstBin + 1;
    }
}
