package com.omnivise.service;

import com.omnivise.model.Device;

/**
 * A validated, normalised {@code GET /api/alerts/rules} query (issue #89).
 *
 * <p>{@link #parse} is the single place this endpoint's request rule lives. It
 * never throws: the outcome is a {@link Valid} carrying the resolved device
 * selection, or an {@link Invalid} carrying the structured {@code
 * {error, field, message}} body the endpoint returns with {@code 400}, using
 * the same {@code invalid_request} discriminator as issue #72/#73.
 *
 * <p>Unlike {@link AlertQuery}'s {@code deviceId} (a filter that simply matches
 * nothing for an unknown id), a {@code deviceId} here must name a registered
 * device: this endpoint answers "which rules apply to device X", so an unknown
 * id is a client error, not an empty result.
 */
public final class AlertRulesQuery {

    /** Outcome of {@link #parse}. */
    public sealed interface Result permits Valid, Invalid {
    }

    /**
     * A well-formed query. {@code deviceId}/{@code deviceKind} are both
     * {@code null} when no device was requested (absent or blank {@code
     * deviceId}), otherwise both are set from the device registry.
     */
    public record Valid(String deviceId, String deviceKind) implements Result {
    }

    /** A rejected query: the three fields are the {@code 400} response body. */
    public record Invalid(String error, String field, String message) implements Result {
    }

    static final String ERROR_CODE = "invalid_request";

    private AlertRulesQuery() {
    }

    /**
     * Validates the raw {@code deviceId} query-parameter value.
     *
     * @param deviceId raw {@code deviceId} value; blank is treated as absent
     * @param devices  registry used to resolve the device's kind and reject an
     *                 unknown id
     */
    public static Result parse(String deviceId, DeviceService devices) {
        String normalised = blankToNull(deviceId);
        if (normalised == null) {
            return new Valid(null, null);
        }
        Device device = devices.getDevice(normalised).orElse(null);
        if (device == null) {
            return new Invalid(ERROR_CODE, "deviceId", "unknown device");
        }
        return new Valid(normalised, device.kind());
    }

    private static String blankToNull(String value) {
        return (value == null || value.isBlank()) ? null : value.trim();
    }
}
