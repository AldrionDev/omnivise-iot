package com.omnivise.service;

import java.time.Instant;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;

import com.omnivise.handler.AlertMessage;
import com.omnivise.handler.WebSocketHandler;
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

    private final AlertService alertService;
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
            AlertService alertService,
            AlertRuleService ruleService,
            DeviceService devices,
            WebSocketHandler wsHandler,
            AlertWebhook webhook) {
        this(alertService, ruleService.getRules(), devices, wsHandler, webhook, Instant::now);
    }

    /** Test seam: explicit rule list and clock. */
    AlertEvaluator(
            AlertService alertService,
            List<AlertRule> rules,
            DeviceService devices,
            WebSocketHandler wsHandler,
            AlertWebhook webhook,
            Supplier<Instant> clock) {
        this.alertService = alertService;
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
        AlertEvent pending = new AlertEvent(null, 0, rule.ruleId(), reading.deviceId(),
                reading.channel(), rule.severity(), AlertEvent.STATE_FIRING,
                value, value, startedAt, null);

        AlertEvent persisted = alertService.insertFiring(pending);                       // (1) persist
        firing.put(key, persisted);                                                     // (2) state
        wsHandler.broadcast(AlertMessage.of(persisted));                                // (3) WS
        safeDispatch(persisted);                                                        // (4) webhook
    }

    private void onClear(SensorReading reading, double value, Key key, AlertEvent current) {
        String resolvedAt = clock.get().toString();
        AlertEvent resolved = alertService.resolve(current, value, resolvedAt).orElse(null); // (1) persist
        if (resolved == null) {
            return;
        }

        firing.remove(key);                                                             // (2) state
        wsHandler.broadcast(AlertMessage.of(resolved));                                 // (3) WS
        safeDispatch(resolved);                                                         // (4) webhook
    }

    private void onRepeatedBreach(double value, Key key, AlertEvent current) {
        if (alertService.updateLastValue(current, value)) {                              // persist only
            firing.put(key, withLastValue(current, value));
        }
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
        alertService.findFiring().forEach(event -> {
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

    private static AlertEvent withLastValue(AlertEvent e, double lastValue) {
        return new AlertEvent(e.id(), e.sequence(), e.ruleId(), e.deviceId(), e.channel(), e.severity(),
                e.state(), e.triggeredValue(), lastValue, e.startedAt(), e.resolvedAt());
    }
}
