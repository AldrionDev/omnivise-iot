package com.omnivise.model;

/**
 * A stateful alert occurrence (issue #73): one rule breaching for one
 * {@code deviceId}/{@code channel}, from first breach ({@code firing}) to the
 * value clearing past the hysteresis threshold ({@code resolved}).
 *
 * <p>Deliberately minimal — the seeded rule holds the policy, this holds only
 * what a consumer needs. Dates are ISO-8601 UTC strings here and BSON
 * {@code Date} in Mongo (see {@code AlertEventMapper}). {@link #resolvedAt()} is
 * {@code null} while {@link #state()} is {@value #STATE_FIRING} and populated
 * once {@value #STATE_RESOLVED}.
 *
 * @param id             Mongo {@code _id} hex string; {@code null} before insert
 * @param sequence       global alert transition sequence; legacy events use zero
 * @param ruleId         the rule that produced this event
 * @param deviceId       the breaching device
 * @param channel        the breaching channel
 * @param severity       copied from the rule at firing time
 * @param state          {@value #STATE_FIRING} or {@value #STATE_RESOLVED}
 * @param triggeredValue the value at first breach; never changes
 * @param lastValue      the most recent evaluated value for this event
 * @param startedAt      first-breach timestamp (always present)
 * @param resolvedAt     clear timestamp; {@code null} while firing
 */
public record AlertEvent(
        String id,
        long sequence,
        String ruleId,
        String deviceId,
        String channel,
        String severity,
        String state,
        double triggeredValue,
        double lastValue,
        String startedAt,
        String resolvedAt
) {
    public static final String STATE_FIRING = "firing";
    public static final String STATE_RESOLVED = "resolved";

    public AlertEvent {
        if (sequence < 0) {
            throw new IllegalArgumentException("sequence must be nonnegative");
        }
    }
}
