package com.omnivise.mapper;

import java.time.Instant;
import java.util.Date;

import org.bson.Document;
import org.bson.types.ObjectId;

import com.omnivise.model.AlertEvent;

/**
 * The single {@code Document <-> AlertEvent} mapper (issue #73).
 *
 * <p>Used by the hot path ({@code AlertEvaluator} inserts), the REST read path
 * ({@code AlertService}) and startup recovery, so the {@code alert_events} shape
 * is defined in exactly one place. Stored timestamps are BSON {@code Date};
 * {@link AlertEvent} carries ISO-8601 UTC strings. A firing event has no
 * {@code resolvedAt} key.
 */
public final class AlertEventMapper {

    private AlertEventMapper() {
    }

    public static AlertEvent fromDocument(Document doc) {
        Object rawId = doc.get("_id");
        return new AlertEvent(
                rawId == null ? null : rawId.toString(),
                doc.getString("ruleId"),
                doc.getString("deviceId"),
                doc.getString("channel"),
                doc.getString("severity"),
                doc.getString("state"),
                toDouble(doc.get("triggeredValue")),
                toDouble(doc.get("lastValue")),
                toIso(doc.get("startedAt")),
                toIso(doc.get("resolvedAt")));
    }

    public static Document toDocument(AlertEvent event) {
        Document doc = new Document();
        if (event.id() != null) {
            doc.append("_id", new ObjectId(event.id()));
        }
        doc.append("ruleId", event.ruleId())
                .append("deviceId", event.deviceId())
                .append("channel", event.channel())
                .append("severity", event.severity())
                .append("state", event.state())
                .append("triggeredValue", event.triggeredValue())
                .append("lastValue", event.lastValue())
                .append("startedAt", fromIso(event.startedAt()));
        if (event.resolvedAt() != null) {
            doc.append("resolvedAt", fromIso(event.resolvedAt()));
        }
        return doc;
    }

    private static double toDouble(Object value) {
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        throw new IllegalArgumentException("alert_events: expected a numeric value, got " + value);
    }

    private static String toIso(Object timestamp) {
        if (timestamp == null) {
            return null;
        }
        if (timestamp instanceof Date date) {
            return date.toInstant().toString();
        }
        if (timestamp instanceof Instant instant) {
            return instant.toString();
        }
        return timestamp.toString();
    }

    private static Date fromIso(String iso) {
        return Date.from(Instant.parse(iso));
    }
}
