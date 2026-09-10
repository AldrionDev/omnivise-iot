package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.bson.Document;
import org.junit.jupiter.api.Test;

import com.omnivise.model.AlertRule;

/**
 * Loading and validation of the seeded {@code alert_rules} registry (issue #73).
 *
 * <p>The registry is authoritative configuration. Enabled rules are loaded into
 * memory in seed order; {@code enabled:false} rows are ignored. A malformed
 * <em>enabled</em> rule is not silently skipped — it fails construction so the
 * backend refuses to start with an incomplete alert policy. Tests drive the
 * package-private {@code List<Document>} seam, mirroring {@code DeviceService}.
 */
class AlertRuleServiceTest {

    private static Document rule(String ruleId) {
        return new Document("_id", ruleId)
                .append("ruleId", ruleId)
                .append("enabled", true)
                .append("match", new Document("deviceId", "ups-1")
                        .append("deviceKind", null)
                        .append("channel", "input_voltage"))
                .append("operator", "<")
                .append("threshold", 180)
                .append("clearThreshold", 210)
                .append("severity", "critical");
    }

    private static AlertRuleService load(Document... docs) {
        return new AlertRuleService(List.of(docs));
    }

    private static IllegalStateException rejects(Document doc) {
        return assertThrows(IllegalStateException.class, () -> load(doc));
    }

    // ------------------------------------------------------------------
    // Happy path
    // ------------------------------------------------------------------

    @Test
    void loadsEveryEnabledRuleInSeedOrder() {
        AlertRuleService service = load(rule("a"), rule("b"), rule("c"));

        assertEquals(List.of("a", "b", "c"),
                service.getRules().stream().map(AlertRule::ruleId).toList());
    }

    @Test
    void mapsAllRuleFieldsIncludingTheNestedMatcher() {
        AlertRule loaded = load(rule("ups-input-voltage-low")).getRules().get(0);

        assertEquals("ups-input-voltage-low", loaded.ruleId());
        assertTrue(loaded.enabled());
        assertEquals("ups-1", loaded.match().deviceId());
        assertEquals(null, loaded.match().deviceKind());
        assertEquals("input_voltage", loaded.match().channel());
        assertEquals("<", loaded.operator());
        assertEquals(180.0, loaded.threshold());
        assertEquals(210.0, loaded.clearThreshold());
        assertEquals("critical", loaded.severity());
    }

    @Test
    void acceptsADeviceKindMatcherAndAGreaterThanRule() {
        Document doc = rule("rack-intake-temp-high")
                .append("match", new Document("deviceId", null)
                        .append("deviceKind", "rack")
                        .append("channel", "intake_temp"))
                .append("operator", ">")
                .append("threshold", 30)
                .append("clearThreshold", 27)
                .append("severity", "warning");

        AlertRule loaded = load(doc).getRules().get(0);

        assertEquals("rack", loaded.match().deviceKind());
        assertEquals(AlertRule.Signal.FIRE, loaded.evaluate(false, 31));
    }

    @Test
    void ignoresDisabledRulesWithoutValidatingThem() {
        Document disabledAndMalformed = rule("legacy")
                .append("enabled", false)
                .append("operator", "!!"); // would be rejected if it were enabled

        AlertRuleService service = load(disabledAndMalformed, rule("live"));

        assertEquals(List.of("live"),
                service.getRules().stream().map(AlertRule::ruleId).toList());
    }

    @Test
    void anEmptyRegistryLoadsZeroRules() {
        assertTrue(new AlertRuleService(List.of()).getRules().isEmpty());
    }

    // ------------------------------------------------------------------
    // Fail-closed on a malformed enabled rule
    // ------------------------------------------------------------------

    @Test
    void rejectsABlankRuleId() {
        assertTrue(rejects(rule("  ").append("ruleId", "  ")).getMessage().toLowerCase().contains("ruleid"));
    }

    @Test
    void rejectsADuplicateRuleId() {
        assertThrows(IllegalStateException.class, () -> load(rule("dup"), rule("dup")));
    }

    @Test
    void rejectsARuleWithNeitherDeviceIdNorDeviceKind() {
        Document doc = rule("x").append("match",
                new Document("deviceId", null).append("deviceKind", null).append("channel", "input_voltage"));
        assertThrows(IllegalStateException.class, () -> load(doc));
    }

    @Test
    void rejectsARuleWithBothDeviceIdAndDeviceKind() {
        Document doc = rule("x").append("match",
                new Document("deviceId", "ups-1").append("deviceKind", "ups").append("channel", "input_voltage"));
        assertThrows(IllegalStateException.class, () -> load(doc));
    }

    @Test
    void rejectsABlankChannel() {
        Document doc = rule("x").append("match",
                new Document("deviceId", "ups-1").append("deviceKind", null).append("channel", "  "));
        assertThrows(IllegalStateException.class, () -> load(doc));
    }

    @Test
    void rejectsAnUnsupportedOperator() {
        assertThrows(IllegalStateException.class, () -> load(rule("x").append("operator", ">=")));
    }

    @Test
    void rejectsAnUnsupportedSeverity() {
        assertThrows(IllegalStateException.class, () -> load(rule("x").append("severity", "fatal")));
    }

    @Test
    void rejectsAGreaterThanRuleWhoseClearThresholdIsNotBelowTheThreshold() {
        Document doc = rule("x")
                .append("operator", ">")
                .append("threshold", 30)
                .append("clearThreshold", 30); // must be strictly below
        assertThrows(IllegalStateException.class, () -> load(doc));
    }

    @Test
    void rejectsALessThanRuleWhoseClearThresholdIsNotAboveTheThreshold() {
        Document doc = rule("x")
                .append("operator", "<")
                .append("threshold", 180)
                .append("clearThreshold", 170); // must be strictly above
        assertThrows(IllegalStateException.class, () -> load(doc));
    }

    @Test
    void rejectsAMissingThreshold() {
        Document doc = rule("x");
        doc.remove("threshold");
        assertThrows(IllegalStateException.class, () -> load(doc));
    }
}
