package com.omnivise.service;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.omnivise.model.AlertRule;

/**
 * In-memory view of the seeded, read-only {@code alert_rules} registry (issue
 * #73).
 *
 * <p>The registry is authoritative alerting configuration. Every enabled rule is
 * loaded once at construction, in seed order; {@code enabled:false} rows are
 * ignored (and not validated). A malformed <em>enabled</em> rule is a
 * configuration error: construction throws {@link IllegalStateException} rather
 * than dropping the rule, so the backend refuses to start with a silently
 * incomplete alert policy.
 */
public class AlertRuleService {

    private static final Set<String> ALLOWED_OPERATORS =
            Set.of(AlertRule.OP_GREATER_THAN, AlertRule.OP_LESS_THAN);
    private static final Set<String> ALLOWED_SEVERITIES = Set.of("warning", "critical");

    private final List<AlertRule> rules;

    /**
     * Connects to MongoDB, reads the whole {@code alert_rules} collection and
     * loads the enabled rules into memory.
     *
     * @param mongoUri MongoDB connection URI
     * @param database database name (e.g. {@code omnivise_iot})
     */
    public AlertRuleService(String mongoUri, String database) {
        this(readAll(mongoUri, database));
    }

    /**
     * Test seam: build the registry directly from {@code alert_rules} documents,
     * without a live MongoDB.
     */
    AlertRuleService(List<Document> ruleDocuments) {
        List<AlertRule> loaded = new ArrayList<>();
        Set<String> seenIds = new LinkedHashSet<>();
        for (Document doc : ruleDocuments) {
            if (!Boolean.TRUE.equals(doc.getBoolean("enabled", false))) {
                continue;
            }
            AlertRule rule = toRule(doc);
            validate(rule);
            if (!seenIds.add(rule.ruleId())) {
                throw invalid(rule.ruleId(), "duplicate ruleId");
            }
            loaded.add(rule);
        }
        this.rules = List.copyOf(loaded);
        System.out.println("✅ Alert rules loaded: " + this.rules.size() + " enabled rule(s)");
    }

    /** The enabled rules, in seed order. */
    public List<AlertRule> getRules() {
        return rules;
    }

    /**
     * The enabled rules applicable to one device, in seed order (issue #89:
     * {@code GET /api/alerts/rules?deviceId=}).
     *
     * <p>Applicability is channel-independent — the caller resolves {@code
     * deviceKind} from {@code DeviceService} once and passes it in here.
     *
     * @param deviceId   the device's id
     * @param deviceKind the device's kind, as resolved from the device registry
     */
    public List<AlertRule> getRulesForDevice(String deviceId, String deviceKind) {
        return rules.stream()
                .filter(rule -> rule.matchesDevice(deviceId, deviceKind))
                .toList();
    }

    /**
     * Maps an {@code alert_rules} document to an {@link AlertRule}. Numbers are
     * read leniently ({@code int} or {@code double} both seed fine).
     */
    static AlertRule toRule(Document doc) {
        Document match = doc.get("match", Document.class);
        if (match == null) {
            throw invalid(doc.getString("ruleId"), "missing match sub-document");
        }
        AlertRule.Matcher matcher = new AlertRule.Matcher(
                blankToNull(match.getString("deviceId")),
                blankToNull(match.getString("deviceKind")),
                match.getString("channel"));
        return new AlertRule(
                doc.getString("ruleId"),
                true,
                matcher,
                doc.getString("operator"),
                toDouble(doc.get("threshold"), doc.getString("ruleId"), "threshold"),
                toDouble(doc.get("clearThreshold"), doc.getString("ruleId"), "clearThreshold"),
                doc.getString("severity"));
    }

    private static void validate(AlertRule rule) {
        String id = rule.ruleId();
        if (isBlank(id)) {
            throw invalid(id, "blank ruleId");
        }
        AlertRule.Matcher m = rule.match();
        boolean hasDeviceId = !isBlank(m.deviceId());
        boolean hasDeviceKind = !isBlank(m.deviceKind());
        if (hasDeviceId == hasDeviceKind) {
            throw invalid(id, "exactly one of match.deviceId / match.deviceKind must be set");
        }
        if (isBlank(m.channel())) {
            throw invalid(id, "blank match.channel");
        }
        if (!ALLOWED_OPERATORS.contains(rule.operator())) {
            throw invalid(id, "unsupported operator '" + rule.operator() + "', must be > or <");
        }
        if (!ALLOWED_SEVERITIES.contains(rule.severity())) {
            throw invalid(id, "unsupported severity '" + rule.severity() + "', must be warning or critical");
        }
        boolean high = AlertRule.OP_GREATER_THAN.equals(rule.operator());
        boolean hysteresisOk = high
                ? rule.clearThreshold() < rule.threshold()
                : rule.clearThreshold() > rule.threshold();
        if (!hysteresisOk) {
            throw invalid(id, "clearThreshold " + rule.clearThreshold()
                    + " must be " + (high ? "below" : "above") + " threshold " + rule.threshold()
                    + " for a '" + rule.operator() + "' rule");
        }
    }

    private static IllegalStateException invalid(String ruleId, String reason) {
        return new IllegalStateException(
                "invalid alert rule configuration [" + ruleId + "]: " + reason);
    }

    private static double toDouble(Object value, String ruleId, String field) {
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        throw invalid(ruleId, "missing or non-numeric " + field);
    }

    private static String blankToNull(String value) {
        return isBlank(value) ? null : value;
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }

    private static List<Document> readAll(String mongoUri, String database) {
        try (MongoClient client = MongoClients.create(mongoUri)) {
            List<Document> docs = new ArrayList<>();
            client.getDatabase(database).getCollection("alert_rules").find().forEach(docs::add);
            return docs;
        }
    }
}
