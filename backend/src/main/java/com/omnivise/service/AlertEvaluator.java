package com.omnivise.service;

import java.time.Instant;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

import org.bson.Document;
import org.bson.types.ObjectId;

import com.mongodb.client.MongoCollection;
import com.mongodb.client.model.Filters;
import com.mongodb.client.model.Updates;
import com.mongodb.client.result.InsertOneResult;
import com.omnivise.handler.AlertMessage;
import com.omnivise.handler.WebSocketHandler;
import com.omnivise.mapper.AlertEventMapper;
import com.omnivise.model.AlertEvent;
import com.omnivise.model.AlertRule;
import com.omnivise.model.Device;
import com.omnivise.model.SensorReading;
import com.omnivise.webhook.AlertWebhook;

/**
 * Stateful threshold-rule evaluation on the Change Stream hot path (issue #73).
 *
 * <p>{@link #evaluate} runs inline for every inserted reading — no scheduler.
 * For each matching rule it dedups on {@code (ruleId, deviceId, channel)}: the
 * first breach inserts one {@code firing} {@code alert_events} document, repeated
 * breaches only update {@code lastValue}, and clearing past the hysteresis
 * threshold transitions the same document to {@code resolved}.
 *
 * <p>Transition ordering is strict: <em>persist</em> the DB write, <em>then</em>
 * update the in-memory firing map, <em>then</em> emit the {@code {kind:"alert"}}
 * WS envelope, <em>then</em> dispatch the webhook. A DB write that throws leaves
 * no phantom in-memory state and emits no side effects. Every per-rule failure
 * is logged and contained so one rule (or a webhook) can never break the stream.
 *
 * <p>The firing map and {@link #evaluate} are touched only by the single Change
 * Stream thread; startup recovery runs once in the constructor, before that
 * thread starts.
 */
public class AlertEvaluator {

    private final MongoCollection<Document> events;
    private final List<AlertRule> rules;
    private final DeviceService devices;
    private final WebSocketHandler wsHandler;
    private final AlertWebhook webhook;
    private final Supplier<Instant> clock;

    /** {@code (ruleId, deviceId, channel)} -> the currently firing event. */
    private final Map<Key, AlertEvent> firing = new HashMap<>();

    private record Key(String ruleId, String deviceId, String channel) {
    }

    /** Production wiring: evaluate the enabled seeded rules, real clock. */
    public AlertEvaluator(
            MongoCollection<Document> events,
            AlertRuleService ruleService,
            DeviceService devices,
            WebSocketHandler wsHandler,
            AlertWebhook webhook) {
        this(events, ruleService.getRules(), devices, wsHandler, webhook, Instant::now);
    }

    /** Test seam: explicit rule list and clock. */
    AlertEvaluator(
            MongoCollection<Document> events,
            List<AlertRule> rules,
            DeviceService devices,
            WebSocketHandler wsHandler,
            AlertWebhook webhook,
            Supplier<Instant> clock) {
        this.events = events;
        this.rules = List.copyOf(rules);
        this.devices = devices;
        this.wsHandler = wsHandler;
        this.webhook = webhook;
        this.clock = clock;
        recoverFiringState();
    }

    /**
     * Evaluates one reading against every matching rule. Non-numeric values are
     * ignored. Never throws: a per-rule failure is logged and skipped.
     */
    public void evaluate(SensorReading reading) {
        if (!(reading.value() instanceof Number number)) {
            return;
        }
        double value = number.doubleValue();
        String deviceKind = devices.getDevice(reading.deviceId())
                .map(Device::kind).orElse(null);

        for (AlertRule rule : rules) {
            try {
                if (!rule.matches(reading.deviceId(), deviceKind, reading.channel())) {
                    continue;
                }
                Key key = new Key(rule.ruleId(), reading.deviceId(), reading.channel());
                AlertEvent current = firing.get(key);
                switch (rule.evaluate(current != null, value)) {
                    case FIRE -> onFire(rule, reading, value, key);
                    case CLEAR -> onClear(reading, value, key, current);
                    case NONE -> {
                        if (current != null) {
                            onRepeatedBreach(value, key, current);
                        }
                    }
                }
            } catch (RuntimeException e) {
                System.err.println("⚠️ Alert evaluation failed for rule " + rule.ruleId()
                        + " on " + reading.deviceId() + "/" + reading.channel() + ": " + e);
            }
        }
    }

    private void onFire(AlertRule rule, SensorReading reading, double value, Key key) {
        String startedAt = clock.get().toString();
        AlertEvent pending = new AlertEvent(null, rule.ruleId(), reading.deviceId(),
                reading.channel(), rule.severity(), AlertEvent.STATE_FIRING,
                value, value, startedAt, null);

        InsertOneResult result = events.insertOne(AlertEventMapper.toDocument(pending)); // (1) persist
        String id = result.getInsertedId().asObjectId().getValue().toHexString();

        AlertEvent persisted = withId(pending, id);
        firing.put(key, persisted);                                                     // (2) state
        wsHandler.broadcast(AlertMessage.of(persisted));                                // (3) WS
        safeDispatch(persisted);                                                        // (4) webhook
    }

    private void onClear(SensorReading reading, double value, Key key, AlertEvent current) {
        String resolvedAt = clock.get().toString();
        events.updateOne(                                                               // (1) persist
                Filters.eq("_id", new ObjectId(current.id())),
                Updates.combine(
                        Updates.set("state", AlertEvent.STATE_RESOLVED),
                        Updates.set("lastValue", value),
                        Updates.set("resolvedAt", Date.from(Instant.parse(resolvedAt)))));

        firing.remove(key);                                                             // (2) state
        AlertEvent resolved = new AlertEvent(current.id(), current.ruleId(),
                current.deviceId(), current.channel(), current.severity(),
                AlertEvent.STATE_RESOLVED, current.triggeredValue(), value,
                current.startedAt(), resolvedAt);
        wsHandler.broadcast(AlertMessage.of(resolved));                                 // (3) WS
        safeDispatch(resolved);                                                         // (4) webhook
    }

    private void onRepeatedBreach(double value, Key key, AlertEvent current) {
        events.updateOne(                                                               // persist only
                Filters.eq("_id", new ObjectId(current.id())),
                Updates.set("lastValue", value));
        firing.put(key, withLastValue(current, value));
        // no state change, no WS, no webhook
    }

    private void safeDispatch(AlertEvent event) {
        try {
            webhook.dispatch(event);
        } catch (RuntimeException e) {
            System.err.println("⚠️ Alert webhook dispatch failed for " + event.ruleId() + ": " + e);
        }
    }

    private void recoverFiringState() {
        events.find(new Document("state", AlertEvent.STATE_FIRING)).forEach((Document doc) -> {
            AlertEvent event = AlertEventMapper.fromDocument(doc);
            Key key = new Key(event.ruleId(), event.deviceId(), event.channel());
            AlertEvent previous = firing.putIfAbsent(key, event);
            if (previous != null) {
                throw new IllegalStateException("ambiguous duplicate firing alert_events for "
                        + key + " (ids " + previous.id() + ", " + event.id()
                        + "); refusing to start");
            }
        });
        if (!firing.isEmpty()) {
            System.out.println("↻ Recovered " + firing.size() + " firing alert(s) from alert_events");
        }
    }

    private static AlertEvent withId(AlertEvent e, String id) {
        return new AlertEvent(id, e.ruleId(), e.deviceId(), e.channel(), e.severity(),
                e.state(), e.triggeredValue(), e.lastValue(), e.startedAt(), e.resolvedAt());
    }

    private static AlertEvent withLastValue(AlertEvent e, double lastValue) {
        return new AlertEvent(e.id(), e.ruleId(), e.deviceId(), e.channel(), e.severity(),
                e.state(), e.triggeredValue(), lastValue, e.startedAt(), e.resolvedAt());
    }
}
