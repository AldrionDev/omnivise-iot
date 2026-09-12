package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyDouble;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.doReturn;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;

import org.bson.Document;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.InOrder;

import com.omnivise.handler.AlertMessage;
import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.AlertEvent;
import com.omnivise.model.AlertRule;
import com.omnivise.model.AlertRule.Matcher;
import com.omnivise.model.SensorReading;
import com.omnivise.webhook.AlertWebhook;

class AlertEvaluatorTest {

    private static final AlertRule VOLTAGE_LOW = new AlertRule("ups-input-voltage-low", true,
            new Matcher("ups-1", null, "input_voltage"), "<", 180, 210, "critical");
    private static final AlertRule INTAKE_HIGH = new AlertRule("rack-intake-temp-high", true,
            new Matcher(null, "rack", "intake_temp"), ">", 30, 27, "warning");

    private final AlertService alertService = mock(AlertService.class);
    private final WebSocketHandler wsHandler = mock(WebSocketHandler.class);
    private final RecordingWebhook webhook = new RecordingWebhook();
    private final AtomicLong sequence = new AtomicLong();
    private DeviceService devices;

    @BeforeEach
    void setUp() {
        devices = new DeviceService(List.of(
                device("ups-1", "ups", "input_voltage"),
                device("rack-a1", "rack", "intake_temp")));
        when(alertService.findFiring()).thenReturn(List.of());
        when(alertService.insertFiring(any())).thenAnswer(inv -> {
            AlertEvent event = inv.getArgument(0);
            long next = sequence.incrementAndGet();
            String id = String.format("64b7f0000000000000%06d", next);
            return new AlertEvent(id, next, event.ruleId(), event.deviceId(),
                    event.channel(), event.severity(), event.state(), event.triggeredValue(),
                    event.lastValue(), event.startedAt(), event.resolvedAt());
        });
        when(alertService.updateLastValue(any(), anyDouble())).thenReturn(true);
        when(alertService.resolve(any(), anyDouble(), anyString())).thenAnswer(inv -> {
            AlertEvent current = inv.getArgument(0);
            double value = inv.getArgument(1);
            String resolvedAt = inv.getArgument(2);
            long next = sequence.incrementAndGet();
            return Optional.of(new AlertEvent(current.id(), next, current.ruleId(), current.deviceId(),
                    current.channel(), current.severity(), AlertEvent.STATE_RESOLVED,
                    current.triggeredValue(), value, current.startedAt(), resolvedAt));
        });
    }

    @Test
    void firingIsVisibleOnlyAfterPersistenceAndCarriesAllocatedSequence() {
        evaluator().evaluate(reading(2.1));

        InOrder order = inOrder(alertService, wsHandler);
        order.verify(alertService).insertFiring(any());
        order.verify(wsHandler).broadcast(any(AlertMessage.class));
        assertEquals(1, webhook.events.size());
        assertEquals(1L, webhook.events.getFirst().sequence());
        assertEquals(AlertEvent.STATE_FIRING, webhook.events.getFirst().state());
    }

    @Test
    void nonBreachingAndNonNumericReadingsAreInert() {
        AlertEvaluator evaluator = evaluator();

        evaluator.evaluate(reading(230.0));
        evaluator.evaluate(new SensorReading("ups-1", "input_voltage", "offline", "V",
                "2026-09-10T08:00:00Z"));

        verify(alertService, never()).insertFiring(any());
        verifyNoInteractions(wsHandler);
        assertTrue(webhook.events.isEmpty());
    }

    @Test
    void repeatedBreachDoesNotAllocateOrEmitAnotherTransition() {
        AlertEvaluator evaluator = evaluator();
        evaluator.evaluate(reading(2.1));
        evaluator.evaluate(reading(1.8));

        verify(alertService, times(1)).insertFiring(any());
        verify(alertService).updateLastValue(any(), anyDouble());
        verify(alertService, never()).resolve(any(), anyDouble(), anyString());
        verify(wsHandler, times(1)).broadcast(any(AlertMessage.class));
        assertEquals(1L, sequence.get());
        assertEquals(1, webhook.events.size());
    }

    @Test
    void resolveEmitsTheCommittedMonotonicTransition() {
        AlertEvaluator evaluator = evaluator();
        evaluator.evaluate(reading(2.1));
        evaluator.evaluate(reading(231.0));

        assertEquals(List.of(1L, 2L), webhook.events.stream().map(AlertEvent::sequence).toList());
        assertEquals(List.of("firing", "resolved"), webhook.events.stream().map(AlertEvent::state).toList());
        verify(wsHandler, times(2)).broadcast(any(AlertMessage.class));
    }

    @Test
    void aLaterBreachAfterResolveCreatesANewLifecycle() {
        AlertEvaluator evaluator = evaluator();
        evaluator.evaluate(reading(2.1));
        evaluator.evaluate(reading(231.0));
        evaluator.evaluate(reading(3.0));

        verify(alertService, times(2)).insertFiring(any());
        assertEquals(List.of("firing", "resolved", "firing"),
                webhook.events.stream().map(AlertEvent::state).toList());
        assertEquals(List.of(1L, 2L, 3L),
                webhook.events.stream().map(AlertEvent::sequence).toList());
        assertNotEquals(webhook.events.get(0).id(), webhook.events.get(2).id());
    }

    @Test
    void holdBandAndNonMatchingRulesRemainInert() {
        AlertEvaluator evaluator = evaluator(INTAKE_HIGH);
        evaluator.evaluate(reading("rack-a1", "intake_temp", 34.0));
        evaluator.evaluate(reading("rack-a1", "intake_temp", 28.5));
        evaluator.evaluate(reading("ups-1", "battery_pct", 2.0));

        verify(alertService, times(1)).insertFiring(any());
        verify(alertService, never()).resolve(any(), anyDouble(), anyString());
        verify(wsHandler, times(1)).broadcast(any(AlertMessage.class));
    }

    @Test
    void distinctMatchingRulesAllocateIndependentTransitions() {
        AlertRule critical = new AlertRule("rack-a1-intake-critical", true,
                new Matcher("rack-a1", null, "intake_temp"), ">", 32, 29, "critical");

        evaluator(critical, INTAKE_HIGH).evaluate(reading("rack-a1", "intake_temp", 33.0));

        verify(alertService, times(2)).insertFiring(any());
        assertEquals(List.of(1L, 2L), webhook.events.stream().map(AlertEvent::sequence).toList());
        assertEquals(2, webhook.events.stream().map(AlertEvent::ruleId).distinct().count());
    }

    @Test
    void throwingWebhookDoesNotUndoCommittedStateOrBreakEvaluation() {
        AlertWebhook throwing = event -> {
            throw new IllegalStateException("unavailable");
        };
        AlertEvaluator evaluator = new AlertEvaluator(alertService, List.of(VOLTAGE_LOW), devices,
                wsHandler, throwing, () -> Instant.parse("2026-09-10T08:00:00Z"));

        evaluator.evaluate(reading(2.1));
        evaluator.evaluate(reading(1.8));

        verify(alertService).insertFiring(any());
        verify(alertService).updateLastValue(any(), anyDouble());
        verify(wsHandler).broadcast(any(AlertMessage.class));
    }

    @Test
    void failedFiringTransactionLeavesNoMemoryOrExternalSideEffectsAndRetries() {
        AlertEvent committed = new AlertEvent("64b7f0000000000000000002", 1L,
                VOLTAGE_LOW.ruleId(), "ups-1", "input_voltage", "critical", "firing",
                2.0, 2.0, "2026-09-10T08:00:00Z", null);
        doThrow(new IllegalStateException("transaction failed"))
                .doReturn(committed)
                .when(alertService).insertFiring(any());

        AlertEvaluator evaluator = evaluator();
        evaluator.evaluate(reading(2.1));
        verifyNoInteractions(wsHandler);
        assertTrue(webhook.events.isEmpty());

        evaluator.evaluate(reading(2.0));
        verify(alertService, times(2)).insertFiring(any());
        verify(wsHandler).broadcast(any(AlertMessage.class));
        assertEquals(1, webhook.events.size());
    }

    @Test
    void failedResolveTransactionKeepsFiringAndEmitsNoResolvedSideEffects() {
        AlertEvaluator evaluator = evaluator();
        evaluator.evaluate(reading(2.1));
        doThrow(new IllegalStateException("transaction failed"))
                .when(alertService).resolve(any(), anyDouble(), anyString());

        evaluator.evaluate(reading(231.0));

        verify(wsHandler, times(1)).broadcast(any(AlertMessage.class));
        assertEquals(1, webhook.events.size());
        assertEquals("firing", webhook.events.getFirst().state());
    }

    @Test
    void resolveCasMissKeepsFiringAndEmitsNoResolvedSideEffects() {
        AlertEvaluator evaluator = evaluator();
        evaluator.evaluate(reading(2.1));
        doReturn(Optional.empty()).when(alertService).resolve(any(), anyDouble(), anyString());

        evaluator.evaluate(reading(231.0));

        verify(wsHandler, times(1)).broadcast(any(AlertMessage.class));
        assertEquals(1, webhook.events.size());
        evaluator.evaluate(reading(1.5));
        verify(alertService).updateLastValue(any(), anyDouble());
    }

    @Test
    void recoveredLegacyFiringEventUsesSequenceZeroAndDoesNotDuplicate() {
        AlertEvent legacy = new AlertEvent("64b7f00000000000000000aa", 0L,
                VOLTAGE_LOW.ruleId(), "ups-1", "input_voltage", "critical", "firing",
                2.0, 2.0, "2026-09-10T07:55:00Z", null);
        when(alertService.findFiring()).thenReturn(List.of(legacy));

        evaluator().evaluate(reading(1.5));

        verify(alertService, never()).insertFiring(any());
        verify(alertService).updateLastValue(legacy, 1.5);
        verifyNoInteractions(wsHandler);
    }

    @Test
    void duplicateRecoveredFiringEventsStillFailStartup() {
        AlertEvent first = new AlertEvent("64b7f00000000000000000aa", 1L,
                VOLTAGE_LOW.ruleId(), "ups-1", "input_voltage", "critical", "firing",
                2.0, 2.0, "2026-09-10T07:55:00Z", null);
        AlertEvent second = new AlertEvent("64b7f00000000000000000bb", 2L,
                VOLTAGE_LOW.ruleId(), "ups-1", "input_voltage", "critical", "firing",
                1.0, 1.0, "2026-09-10T07:56:00Z", null);
        when(alertService.findFiring()).thenReturn(List.of(first, second));

        assertThrows(IllegalStateException.class, this::evaluator);
    }

    private AlertEvaluator evaluator(AlertRule... rules) {
        List<AlertRule> configuredRules = rules.length == 0 ? List.of(VOLTAGE_LOW) : List.of(rules);
        return new AlertEvaluator(alertService, configuredRules, devices, wsHandler, webhook,
                () -> Instant.parse("2026-09-10T08:00:00Z"));
    }

    private static SensorReading reading(double value) {
        return new SensorReading("ups-1", "input_voltage", value, "V", "2026-09-10T08:00:00Z");
    }

    private static SensorReading reading(String deviceId, String channel, double value) {
        return new SensorReading(deviceId, channel, value, "x", "2026-09-10T08:00:00Z");
    }

    private static Document device(String deviceId, String kind, String channel) {
        return new Document("deviceId", deviceId)
                .append("name", deviceId)
                .append("kind", kind)
                .append("location", "Server Room")
                .append("channels", List.of(new Document("channel", channel).append("unit", "x")));
    }

    private static final class RecordingWebhook implements AlertWebhook {
        private final List<AlertEvent> events = new ArrayList<>();

        @Override
        public void dispatch(AlertEvent event) {
            events.add(event);
        }
    }
}
