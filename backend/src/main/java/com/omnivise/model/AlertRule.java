package com.omnivise.model;

/**
 * A seeded, read-only threshold rule (issue #73).
 *
 * <p>A rule is a {@link Matcher} (which readings it applies to) plus a condition
 * (an {@code operator}, a {@code threshold} and a hysteresis {@code
 * clearThreshold}). The two pure behaviours it owns are {@link #matches} and
 * {@link #evaluate}; loading and validation are {@code AlertRuleService}'s job,
 * and stateful dedup is {@code AlertEvaluator}'s.
 *
 * @param ruleId         stable identifier, unique across the seeded set
 * @param enabled        only enabled rules are evaluated
 * @param match          the matcher: device id <em>or</em> device kind, + channel
 * @param operator       {@code ">"} (high) or {@code "<"} (low)
 * @param threshold      firing boundary (strict)
 * @param clearThreshold hysteresis boundary (strict); for {@code ">"} it is
 *                       below {@code threshold}, for {@code "<"} it is above it
 * @param severity       {@code "warning"} or {@code "critical"}
 */
public record AlertRule(
        String ruleId,
        boolean enabled,
        Matcher match,
        String operator,
        double threshold,
        double clearThreshold,
        String severity
) {

    /** {@code ">"} — fire above the threshold. */
    public static final String OP_GREATER_THAN = ">";
    /** {@code "<"} — fire below the threshold. */
    public static final String OP_LESS_THAN = "<";

    /**
     * Which readings a rule applies to. Exactly one of {@link #deviceId()} /
     * {@link #deviceKind()} is non-null (enforced at load time); {@link
     * #channel()} is always required.
     */
    public record Matcher(String deviceId, String deviceKind, String channel) {

        /** Whether this matcher applies to a reading on the given device/channel. */
        public boolean matches(String readingDeviceId, String readingDeviceKind, String readingChannel) {
            return channel.equals(readingChannel) && matchesDevice(readingDeviceId, readingDeviceKind);
        }

        /**
         * Whether this matcher's device selector ({@code deviceId} or {@code
         * deviceKind}) applies to the given device, independent of channel (issue
         * #89: {@code GET /api/alerts/rules}).
         */
        public boolean matchesDevice(String candidateDeviceId, String candidateDeviceKind) {
            if (deviceId != null) {
                return deviceId.equals(candidateDeviceId);
            }
            return deviceKind != null && deviceKind.equals(candidateDeviceKind);
        }
    }

    /** Outcome of {@link AlertRule#evaluate}: a firing/clearing transition, or no change. */
    public enum Signal {
        /** The value crossed the threshold while not firing. */
        FIRE,
        /** The value crossed the clearThreshold while firing. */
        CLEAR,
        /** No state change (below the threshold, or inside the hold band). */
        NONE
    }

    /** Delegates to {@link Matcher#matches}. */
    public boolean matches(String readingDeviceId, String readingDeviceKind, String readingChannel) {
        return match.matches(readingDeviceId, readingDeviceKind, readingChannel);
    }

    /** Delegates to {@link Matcher#matchesDevice}. */
    public boolean matchesDevice(String deviceId, String deviceKind) {
        return match.matchesDevice(deviceId, deviceKind);
    }

    /**
     * Pure operator + hysteresis evaluation for one reading value.
     *
     * <p>Both boundaries are strict: {@code value == threshold} never fires and
     * {@code value == clearThreshold} never clears. While not firing the only
     * possible transition is {@link Signal#FIRE}; while firing it is {@link
     * Signal#CLEAR}. Everything else is {@link Signal#NONE}.
     *
     * @param currentlyFiring the dedup state for this rule/device/channel
     * @param value           the numeric reading value
     */
    public Signal evaluate(boolean currentlyFiring, double value) {
        boolean high = OP_GREATER_THAN.equals(operator);
        if (!currentlyFiring) {
            boolean breached = high ? value > threshold : value < threshold;
            return breached ? Signal.FIRE : Signal.NONE;
        }
        boolean cleared = high ? value < clearThreshold : value > clearThreshold;
        return cleared ? Signal.CLEAR : Signal.NONE;
    }
}
