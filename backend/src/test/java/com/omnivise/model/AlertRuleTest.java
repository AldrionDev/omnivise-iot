package com.omnivise.model;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

import com.omnivise.model.AlertRule.Matcher;
import com.omnivise.model.AlertRule.Signal;

/**
 * A seeded threshold rule (issue #73): a matcher (device id <em>or</em> device
 * kind, plus a channel) and a condition (operator, threshold, clearThreshold).
 *
 * <p>These tests pin the two pure behaviours the rule owns: does it apply to a
 * given reading ({@link #matcherTests}), and — given the current firing state and
 * a value — does it fire, clear or hold ({@link #operatorTests}). Rule loading
 * and validation live in {@code AlertRuleService}; stateful dedup lives in
 * {@code AlertEvaluator}.
 */
class AlertRuleTest {

    private static AlertRule deviceRule() {
        return new AlertRule("ups-input-voltage-low", true,
                new Matcher("ups-1", null, "input_voltage"), "<", 180, 210, "critical");
    }

    private static AlertRule kindRule() {
        return new AlertRule("rack-intake-temp-high", true,
                new Matcher(null, "rack", "intake_temp"), ">", 30, 27, "warning");
    }

    // ------------------------------------------------------------------
    // Matcher
    // ------------------------------------------------------------------

    @Test
    void deviceIdRuleMatchesOnExactDeviceIdAndChannel() {
        assertTrue(deviceRule().matches("ups-1", "ups", "input_voltage"));
    }

    @Test
    void deviceIdRuleDoesNotMatchAnotherDevice() {
        assertFalse(deviceRule().matches("ups-2", "ups", "input_voltage"));
    }

    @Test
    void deviceKindRuleMatchesAnyDeviceOfThatKindOnTheChannel() {
        assertTrue(kindRule().matches("rack-a1", "rack", "intake_temp"));
        assertTrue(kindRule().matches("rack-a2", "rack", "intake_temp"));
    }

    @Test
    void deviceKindRuleDoesNotMatchADifferentKind() {
        assertFalse(kindRule().matches("crac-1", "crac", "intake_temp"));
    }

    @Test
    void aRuleDoesNotMatchADifferentChannelOnTheRightDevice() {
        assertFalse(deviceRule().matches("ups-1", "ups", "battery_pct"));
        assertFalse(kindRule().matches("rack-a1", "rack", "humidity"));
    }

    // ------------------------------------------------------------------
    // Operator + hysteresis — both boundaries strict, equality is no transition
    // ------------------------------------------------------------------

    @Test
    void greaterThanFiresOnlyStrictlyAboveTheThreshold() {
        AlertRule rule = kindRule(); // > 30, clear 27
        assertEquals(Signal.NONE, rule.evaluate(false, 30.0), "equality does not fire");
        assertEquals(Signal.NONE, rule.evaluate(false, 29.9));
        assertEquals(Signal.FIRE, rule.evaluate(false, 30.1));
    }

    @Test
    void greaterThanClearsOnlyStrictlyBelowTheClearThreshold() {
        AlertRule rule = kindRule(); // > 30, clear 27
        assertEquals(Signal.NONE, rule.evaluate(true, 27.0), "equality does not clear");
        assertEquals(Signal.NONE, rule.evaluate(true, 28.0), "inside the hold band");
        assertEquals(Signal.CLEAR, rule.evaluate(true, 26.9));
    }

    @Test
    void lessThanFiresOnlyStrictlyBelowTheThreshold() {
        AlertRule rule = deviceRule(); // < 180, clear 210
        assertEquals(Signal.NONE, rule.evaluate(false, 180.0), "equality does not fire");
        assertEquals(Signal.NONE, rule.evaluate(false, 181.0));
        assertEquals(Signal.FIRE, rule.evaluate(false, 179.9));
    }

    @Test
    void lessThanClearsOnlyStrictlyAboveTheClearThreshold() {
        AlertRule rule = deviceRule(); // < 180, clear 210
        assertEquals(Signal.NONE, rule.evaluate(true, 210.0), "equality does not clear");
        assertEquals(Signal.NONE, rule.evaluate(true, 200.0), "inside the hold band");
        assertEquals(Signal.CLEAR, rule.evaluate(true, 210.1));
    }
}
