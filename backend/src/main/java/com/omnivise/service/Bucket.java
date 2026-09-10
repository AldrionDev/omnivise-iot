package com.omnivise.service;

import java.time.Duration;
import java.util.Optional;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * The fixed set of down-sampling widths accepted by
 * {@code GET /api/sensors/history} (issue #72).
 *
 * <p>Each constant carries three things: the client-facing {@code label} used in
 * the {@code bucket} query parameter and echoed in the response, the MongoDB
 * {@code $dateTrunc} parameters ({@code truncUnit} + {@code binSize}) used to
 * build the aggregation pipeline, and the {@link Duration} the range/bucket
 * count guard divides the requested range by.
 *
 * <p>The allowed set ({@code 1m}, {@code 5m}, {@code 1h}) and the maximum bucket
 * count are approved maintainer decisions; changing them is a contract change.
 */
public enum Bucket {

    M1("1m", "minute", 1, Duration.ofMinutes(1)),
    M5("5m", "minute", 5, Duration.ofMinutes(5)),
    H1("1h", "hour", 1, Duration.ofHours(1));

    private final String label;
    private final String truncUnit;
    private final int binSize;
    private final Duration duration;

    Bucket(String label, String truncUnit, int binSize, Duration duration) {
        this.label = label;
        this.truncUnit = truncUnit;
        this.binSize = binSize;
        this.duration = duration;
    }

    /**
     * Resolves a {@code bucket} query-parameter value to a {@link Bucket}.
     *
     * @param label raw parameter value, may be {@code null}
     * @return the matching bucket, or {@link Optional#empty()} for a missing,
     *         blank or unrecognised value (matching is case-sensitive)
     */
    public static Optional<Bucket> fromLabel(String label) {
        if (label == null) {
            return Optional.empty();
        }
        return Stream.of(values())
                .filter(b -> b.label.equals(label))
                .findFirst();
    }

    /** Human-readable list of accepted labels, e.g. {@code [1m, 5m, 1h]}. */
    public static String allowedLabels() {
        return Stream.of(values())
                .map(b -> b.label)
                .collect(Collectors.joining(", ", "[", "]"));
    }

    public String label() {
        return label;
    }

    /** {@code $dateTrunc} {@code unit} value. */
    public String truncUnit() {
        return truncUnit;
    }

    /** {@code $dateTrunc} {@code binSize} value. */
    public int binSize() {
        return binSize;
    }

    /** Wall-clock width of one bucket, used by the range/bucket-count guard. */
    public Duration duration() {
        return duration;
    }
}
