package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;
import java.util.stream.Stream;

import org.bson.Document;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

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

    // ------------------------------------------------------------------
    // getRulesForDevice — channel-independent device applicability (issue #89)
    // ------------------------------------------------------------------

    private static Document deviceRule(String ruleId, String deviceId, String channel) {
        return rule(ruleId)
                .append("match", new Document("deviceId", deviceId)
                        .append("deviceKind", null)
                        .append("channel", channel));
    }

    private static Document kindRule(String ruleId, String deviceKind, String channel) {
        return rule(ruleId)
                .append("match", new Document("deviceId", null)
                        .append("deviceKind", deviceKind)
                        .append("channel", channel));
    }

    @Test
    void getRulesForDeviceReturnsBothDeviceKindRulesForARackDevice() {
        AlertRuleService service = load(
                kindRule("rack-intake-temp-high", "rack", "intake_temp"),
                kindRule("rack-humidity-high", "rack", "humidity"),
                deviceRule("crac-return-temp-high", "crac-1", "return_temp"));

        assertEquals(List.of("rack-intake-temp-high", "rack-humidity-high"),
                service.getRulesForDevice("rack-a1", "rack").stream().map(AlertRule::ruleId).toList());
        assertEquals(List.of("rack-intake-temp-high", "rack-humidity-high"),
                service.getRulesForDevice("rack-a2", "rack").stream().map(AlertRule::ruleId).toList());
    }

    @Test
    void getRulesForDeviceReturnsOnlyTheDeviceSpecificRuleForThatExactDevice() {
        AlertRuleService service = load(
                deviceRule("crac-return-temp-high", "crac-1", "return_temp"));

        assertEquals(List.of("crac-return-temp-high"),
                service.getRulesForDevice("crac-1", "crac").stream().map(AlertRule::ruleId).toList());
    }

    @Test
    void getRulesForDeviceDoesNotMatchADeviceSpecificRuleToAnotherDeviceOfTheSameKind() {
        AlertRuleService service = load(
                deviceRule("ups-input-voltage-low", "ups-1", "input_voltage"));

        assertTrue(service.getRulesForDevice("ups-2", "ups").isEmpty());
    }

    @Test
    void getRulesForDeviceReturnsEmptyForADeviceWithNoApplicableRules() {
        AlertRuleService service = load(
                kindRule("rack-intake-temp-high", "rack", "intake_temp"),
                deviceRule("ups-input-voltage-low", "ups-1", "input_voltage"));

        assertTrue(service.getRulesForDevice("pdu-a1", "pdu").isEmpty());
    }

    // ------------------------------------------------------------------
    // Canonical #73 seed: the exact five mongo-init.js alert_rules documents
    // ------------------------------------------------------------------

    private static Document seededRule(String ruleId, String deviceId, String deviceKind, String channel,
            String operator, int threshold, int clearThreshold, String severity, String description) {
        return new Document("_id", ruleId)
                .append("ruleId", ruleId)
                .append("enabled", true)
                .append("match", new Document("deviceId", deviceId)
                        .append("deviceKind", deviceKind)
                        .append("channel", channel))
                .append("operator", operator)
                .append("threshold", threshold)
                .append("clearThreshold", clearThreshold)
                .append("severity", severity)
                .append("description", description);
    }

    private static final AlertRuleService CANONICAL = load(
            seededRule("rack-intake-temp-high", null, "rack", "intake_temp", ">", 30, 27, "warning",
                    "Rack cold-aisle intake temperature is high"),
            seededRule("rack-humidity-high", null, "rack", "humidity", ">", 60, 55, "warning",
                    "Rack relative humidity is high"),
            seededRule("crac-return-temp-high", "crac-1", null, "return_temp", ">", 41, 37, "warning",
                    "CRAC return-air temperature is high"),
            seededRule("ups-input-voltage-low", "ups-1", null, "input_voltage", "<", 180, 210, "critical",
                    "UPS input voltage lost (mains failure)"),
            seededRule("ups-battery-low", "ups-1", null, "battery_pct", "<", 95, 98, "critical",
                    "UPS battery charge is low"));

    private static List<String> ids(List<AlertRule> rules) {
        return rules.stream().map(AlertRule::ruleId).toList();
    }

    @Test
    void canonicalSeedGetRulesReturnsExactlyTheFiveRulesInSeedOrder() {
        assertEquals(List.of(
                        "rack-intake-temp-high",
                        "rack-humidity-high",
                        "crac-return-temp-high",
                        "ups-input-voltage-low",
                        "ups-battery-low"),
                ids(CANONICAL.getRules()));
    }

    static Stream<Arguments> canonicalDeviceMatrix() {
        return Stream.of(
                Arguments.of("rack-a1", "rack", List.of("rack-intake-temp-high", "rack-humidity-high")),
                Arguments.of("rack-a2", "rack", List.of("rack-intake-temp-high", "rack-humidity-high")),
                Arguments.of("crac-1", "crac", List.of("crac-return-temp-high")),
                Arguments.of("ups-1", "ups", List.of("ups-input-voltage-low", "ups-battery-low")),
                Arguments.of("pdu-a1", "pdu", List.of()));
    }

    @ParameterizedTest(name = "{0} ({1}) -> {2}")
    @MethodSource("canonicalDeviceMatrix")
    void canonicalSeedGetRulesForDeviceReturnsExactlyTheApplicableRulesInSeedOrder(
            String deviceId, String deviceKind, List<String> expectedRuleIds) {
        assertEquals(expectedRuleIds, ids(CANONICAL.getRulesForDevice(deviceId, deviceKind)));
    }

    @Test
    void getRulesForDeviceNeverExposesDisabledRules() {
        Document disabled = kindRule("rack-intake-temp-high", "rack", "intake_temp")
                .append("enabled", false)
                .append("operator", "!!"); // would be rejected if it were enabled
        AlertRuleService service = load(disabled);

        assertTrue(service.getRulesForDevice("rack-a1", "rack").isEmpty());
    }
}
