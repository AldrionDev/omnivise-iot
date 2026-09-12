package com.omnivise.service;

import java.util.Set;

import com.omnivise.model.AlertEvent;

/**
 * A validated, normalised {@code GET /api/alerts} query (issue #73).
 *
 * <p>{@link #parse} is the single place the query rules live. It never throws:
 * the outcome is a {@link Valid} carrying this immutable value object, or an
 * {@link Invalid} carrying the structured {@code {error, field, message}} body
 * the endpoint returns with {@code 400}. Validation is fail-fast (first problem
 * only) and uses the same {@code invalid_request} discriminator as issue #72.
 *
 * <p>{@code state} and {@code severity} are checked against fixed sets;
 * {@code limit} must be an integer in {@code [1, }{@value #MAX_LIMIT}{@code ]}
 * and defaults to {@value #DEFAULT_LIMIT}; {@code deviceId} is a free-form
 * filter (an unknown id simply matches nothing). Blank optional values are
 * absent.
 */
public final class AlertQuery {

    /** Outcome of {@link #parse}. */
    public sealed interface Result permits Valid, Invalid {
    }

    /** A well-formed query. */
    public record Valid(AlertQuery query) implements Result {
    }

    /** A rejected query: the three fields are the {@code 400} response body. */
    public record Invalid(String error, String field, String message) implements Result {
    }

    static final String ERROR_CODE = "invalid_request";
    static final int DEFAULT_LIMIT = 100;
    static final int MAX_LIMIT = 500;

    private static final Set<String> STATES =
            Set.of(AlertEvent.STATE_FIRING, AlertEvent.STATE_RESOLVED);
    private static final Set<String> SEVERITIES = Set.of("warning", "critical");

    private final String state;
    private final String severity;
    private final String deviceId;
    private final int limit;

    private AlertQuery(String state, String severity, String deviceId, int limit) {
        this.state = state;
        this.severity = severity;
        this.deviceId = deviceId;
        this.limit = limit;
    }

    /** Validates raw query-parameter values for {@code GET /api/alerts}. */
    public static Result parse(String state, String severity, String deviceId, String limit) {
        String normalisedState = blankToNull(state);
        if (normalisedState != null && !STATES.contains(normalisedState)) {
            return invalid("state", "state must be one of " + STATES);
        }
        String normalisedSeverity = blankToNull(severity);
        if (normalisedSeverity != null && !SEVERITIES.contains(normalisedSeverity)) {
            return invalid("severity", "severity must be one of " + SEVERITIES);
        }

        int resolvedLimit = DEFAULT_LIMIT;
        String rawLimit = blankToNull(limit);
        if (rawLimit != null) {
            try {
                resolvedLimit = Integer.parseInt(rawLimit.trim());
            } catch (NumberFormatException e) {
                return invalid("limit", "limit must be an integer");
            }
            if (resolvedLimit < 1 || resolvedLimit > MAX_LIMIT) {
                return invalid("limit", "limit must be between 1 and " + MAX_LIMIT);
            }
        }

        return new Valid(new AlertQuery(
                normalisedState, normalisedSeverity, blankToNull(deviceId), resolvedLimit));
    }

    /**
     * Validates the {@code GET /api/alerts/active} query, which is
     * {@code GET /api/alerts} with {@code state} fixed to {@value
     * AlertEvent#STATE_FIRING} (the caller cannot override it).
     */
    public static Result forActive(String severity, String deviceId, String limit) {
        return parse(AlertEvent.STATE_FIRING, severity, deviceId, limit);
    }

    public String state() {
        return state;
    }

    public String severity() {
        return severity;
    }

    public String deviceId() {
        return deviceId;
    }

    public int limit() {
        return limit;
    }

    private static Invalid invalid(String field, String message) {
        return new Invalid(ERROR_CODE, field, message);
    }

    private static String blankToNull(String value) {
        return (value == null || value.isBlank()) ? null : value.trim();
    }
}
