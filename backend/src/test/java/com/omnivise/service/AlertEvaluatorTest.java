package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
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
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;
import java.util.function.Supplier;

import org.bson.Document;
import org.bson.conversions.Bson;
import org.bson.types.ObjectId;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

import com.mongodb.client.FindIterable;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.result.InsertOneResult;
import com.omnivise.handler.AlertMessage;
import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.AlertEvent;
import com.omnivise.model.AlertRule;
import com.omnivise.model.AlertRule.Matcher;
import com.omnivise.model.SensorReading;
import com.omnivise.webhook.AlertWebhook;

/**
 * Stateful alert evaluation on the Change Stream hot path (issue #73).
 *
 * <p>MongoDB is mocked (same style as {@code SensorChangeStreamListenerTest}):
 * the tests observe {@code insertOne} / {@code updateOne} calls and the captured
 * documents, a mocked {@link WebSocketHandler}, and a recording {@link
 * AlertWebhook}. The evaluator runs inline on one thread; transitions must
 * persist first, then update in-memory firing state, then emit the WS envelope,
 * then dispatch the webhook.
 */
@SuppressWarnings("unchecked")
class AlertEvaluatorTest {

    private static final AlertRule VOLTAGE_LOW = new AlertRule("ups-input-voltage-low", true,
            new Matcher("ups-1", null, "input_voltage"), "<", 180, 210, "critical");
    private static final AlertRule INTAKE_HIGH = new AlertRule("rack-intake-temp-high", true,
            new Matcher(null, "rack", "intake_temp"), ">", 30, 27, "warning");

    private final MongoCollection<Document> events = mock(MongoCollection.class);
    private final WebSocketHandler wsHandler = mock(WebSocketHandler.class);
    private final RecordingWebhook webhook = new RecordingWebhook();
    private final AtomicInteger insertedIds = new AtomicInteger();
    private final List<Instant> clockReadings = new ArrayList<>(List.of(
            Instant.parse("2026-09-10T08:00:00Z"),
            Instant.parse("2026-09-10T08:01:00Z"),
            Instant.parse("2026-09-10T08:02:00Z"),
            Instant.parse("2026-09-10T08:03:00Z"),
            Instant.parse("2026-09-10T08:04:00Z")));
    private final AtomicInteger clockIndex = new AtomicInteger();

    private DeviceService devices;

    @BeforeEach
    void setUp() {
        devices = new DeviceService(List.of(
                deviceDoc("ups-1", "ups", "input_voltage"),
                deviceDoc("rack-a1", "rack", "intake_temp"),
                deviceDoc("rack-a2", "rack", "intake_temp")));
        stubFind(List.of()); // no firing events to recover, unless a test overrides
        when(events.insertOne(any(Document.class))).thenAnswer(inv ->
                insertResult(String.format("64b7f0000000000000%06d", insertedIds.incrementAndGet())));
    }

    // ------------------------------------------------------------------
    // Slice 5: first breach -> exactly one firing event
    // ------------------------------------------------------------------

    @Test
    void firstBreachInsertsExactlyOneFiringEventWithSeverityTriggeredValueAndStartedAt() {
        evaluator(VOLTAGE_LOW).evaluate(reading("ups-1", "input_voltage", 2.1));

        ArgumentCaptor<Document> doc = ArgumentCaptor.forClass(Document.class);
        verify(events, times(1)).insertOne(doc.capture());
        verify(events, never()).updateOne(any(Bson.class), any(Bson.class));

        assertEquals("ups-input-voltage-low", doc.getValue().getString("ruleId"));
        assertEquals("ups-1", doc.getValue().getString("deviceId"));
        assertEquals("input_voltage", doc.getValue().getString("channel"));
        assertEquals("critical", doc.getValue().getString("severity"));
        assertEquals("firing", doc.getValue().getString("state"));
        assertEquals(2.1, doc.getValue().get("triggeredValue"));
        assertEquals(2.1, doc.getValue().get("lastValue"));
        assertEquals(java.util.Date.from(Instant.parse("2026-09-10T08:00:00Z")),
                doc.getValue().get("startedAt"));
        assertTrue(!doc.getValue().containsKey("resolvedAt"), "a firing event has no resolvedAt");
    }

    @Test
    void firstBreachEmitsAKindAlertEnvelopeAndDispatchesTheWebhookAfterPersistence() {
        evaluator(VOLTAGE_LOW).evaluate(reading("ups-1", "input_voltage", 2.1));

        InOrder order = inOrder(events, wsHandler);
        order.verify(events).insertOne(any(Document.class));
        ArgumentCaptor<AlertMessage> msg = ArgumentCaptor.forClass(AlertMessage.class);
        order.verify(wsHandler).broadcast(msg.capture());

        assertEquals("alert", msg.getValue().kind());
        AlertEvent emitted = msg.getValue().payload();
        assertEquals("firing", emitted.state());
        assertEquals(2.1, emitted.triggeredValue());
        assertNotEquals(null, emitted.id(), "the emitted event carries the persisted id");

        assertEquals(1, webhook.events.size());
        assertEquals("firing", webhook.events.get(0).state());
        assertEquals(emitted.id(), webhook.events.get(0).id(),
                "webhook gets the persisted event (id proves the insert completed first)");
    }

    @Test
    void aReadingBelowTheThresholdButNotBreachingDoesNothing() {
        evaluator(INTAKE_HIGH).evaluate(reading("rack-a1", "intake_temp", 24.0));

        verifyNoInteractions(wsHandler);
        verify(events, never()).insertOne(any(Document.class));
        assertTrue(webhook.events.isEmpty());
    }

    @Test
    void aNonNumericReadingValueIsIgnored() {
        evaluator(INTAKE_HIGH).evaluate(reading("rack-a1", "intake_temp", "closed"));

        verify(events, never()).insertOne(any(Document.class));
        verifyNoInteractions(wsHandler);
    }

    // ------------------------------------------------------------------
    // Slice 6: repeated breach -> lastValue only, no duplicate side effects
    // ------------------------------------------------------------------

    @Test
    void repeatedBreachUpdatesLastValueOnlyWithNoDuplicateEventWsOrWebhook() {
        AlertEvaluator evaluator = evaluator(INTAKE_HIGH);
        evaluator.evaluate(reading("rack-a1", "intake_temp", 34.7)); // FIRE
        evaluator.evaluate(reading("rack-a1", "intake_temp", 35.9)); // still breaching

        verify(events, times(1)).insertOne(any(Document.class));
        ArgumentCaptor<Bson> filter = ArgumentCaptor.forClass(Bson.class);
        ArgumentCaptor<Bson> update = ArgumentCaptor.forClass(Bson.class);
        verify(events, times(1)).updateOne(filter.capture(), update.capture());

        assertTrue(update.getValue().toBsonDocument().toJson().contains("lastValue"));
        assertTrue(!update.getValue().toBsonDocument().toJson().contains("\"state\""),
                "a repeated breach must not touch state");
        verify(wsHandler, times(1)).broadcast(any(AlertMessage.class)); // only the firing envelope
        assertEquals(1, webhook.events.size(), "no webhook for a repeated breach");
    }

    // ------------------------------------------------------------------
    // Slice 7: clear -> same document resolved + resolvedAt + WS + webhook
    // ------------------------------------------------------------------

    @Test
    void clearingTransitionsTheSameDocumentToResolvedWithResolvedAt() {
        AlertEvaluator evaluator = evaluator(VOLTAGE_LOW);
        evaluator.evaluate(reading("ups-1", "input_voltage", 2.1));   // FIRE  @ 08:00
        evaluator.evaluate(reading("ups-1", "input_voltage", 231.0)); // CLEAR @ 08:01

        ArgumentCaptor<Bson> filter = ArgumentCaptor.forClass(Bson.class);
        ArgumentCaptor<Bson> update = ArgumentCaptor.forClass(Bson.class);
        verify(events, times(1)).updateOne(filter.capture(), update.capture());

        String insertedId = String.format("64b7f0000000000000%06d", 1);
        assertTrue(filter.getValue().toBsonDocument().toJson().contains(insertedId),
                "the resolve updates the same document by its persisted _id");
        String updateJson = update.getValue().toBsonDocument().toJson();
        assertTrue(updateJson.contains("resolved"));
        assertTrue(updateJson.contains("resolvedAt"));

        AlertEvent resolved = webhook.events.get(webhook.events.size() - 1);
        assertEquals("resolved", resolved.state());
        assertEquals(insertedId, resolved.id());
        assertEquals(2.1, resolved.triggeredValue(), "triggeredValue is preserved from firing");
        assertEquals(231.0, resolved.lastValue());
        assertEquals("2026-09-10T08:00:00Z", resolved.startedAt());
        assertEquals("2026-09-10T08:01:00Z", resolved.resolvedAt());
        verify(wsHandler, times(2)).broadcast(any(AlertMessage.class)); // firing + resolved
        assertEquals(2, webhook.events.size());
    }

    @Test
    void aValueInsideTheHoldBandDoesNotResolve() {
        AlertEvaluator evaluator = evaluator(INTAKE_HIGH); // > 30, clear 27
        evaluator.evaluate(reading("rack-a1", "intake_temp", 34.0)); // FIRE
        evaluator.evaluate(reading("rack-a1", "intake_temp", 28.5)); // in [27, 30] hold band

        // still firing: only the firing envelope/webhook, no resolve write mentioning "resolved"
        verify(wsHandler, times(1)).broadcast(any(AlertMessage.class));
        assertEquals(1, webhook.events.size());
    }

    // ------------------------------------------------------------------
    // Slice 8: a later breach after resolution creates a new event
    // ------------------------------------------------------------------

    @Test
    void aBreachAfterResolutionCreatesANewFiringEventLeavingTheResolvedOneUntouched() {
        AlertEvaluator evaluator = evaluator(VOLTAGE_LOW);
        evaluator.evaluate(reading("ups-1", "input_voltage", 2.1));    // FIRE  -> event #1
        evaluator.evaluate(reading("ups-1", "input_voltage", 231.0));  // CLEAR -> event #1 resolved
        evaluator.evaluate(reading("ups-1", "input_voltage", 3.4));    // FIRE  -> event #2

        verify(events, times(2)).insertOne(any(Document.class));
        verify(events, times(1)).updateOne(any(Bson.class), any(Bson.class)); // only the resolve

        List<String> firingIds = webhook.events.stream()
                .filter(e -> e.state().equals("firing")).map(AlertEvent::id).toList();
        assertEquals(2, firingIds.size());
        assertNotEquals(firingIds.get(0), firingIds.get(1), "the second breach is a distinct event");
    }

    // ------------------------------------------------------------------
    // Slice 9: two distinct matching rules evaluate independently
    // ------------------------------------------------------------------

    @Test
    void twoDistinctRulesMatchingOneReadingBothProduceTheirOwnEvent() {
        AlertRule strictDeviceRule = new AlertRule("rack-a1-intake-critical", true,
                new Matcher("rack-a1", null, "intake_temp"), ">", 32, 29, "critical");

        // 33 breaches both the deviceId rule (>32) and the deviceKind rule (>30)
        evaluator(strictDeviceRule, INTAKE_HIGH).evaluate(reading("rack-a1", "intake_temp", 33.0));

        ArgumentCaptor<Document> docs = ArgumentCaptor.forClass(Document.class);
        verify(events, times(2)).insertOne(docs.capture());
        List<String> ruleIds = docs.getAllValues().stream().map(d -> d.getString("ruleId")).sorted().toList();
        assertEquals(List.of("rack-a1-intake-critical", "rack-intake-temp-high"), ruleIds);

        verify(wsHandler, times(2)).broadcast(any(AlertMessage.class));
        assertEquals(2, webhook.events.size());
    }

    @Test
    void aReadingMatchingNoRuleIsInert() {
        evaluator(VOLTAGE_LOW, INTAKE_HIGH).evaluate(reading("ups-1", "battery_pct", 20.0));

        verify(events, never()).insertOne(any(Document.class));
        verifyNoInteractions(wsHandler);
        assertTrue(webhook.events.isEmpty());
    }

    // ------------------------------------------------------------------
    // Slice 11: startup recovery of firing state
    // ------------------------------------------------------------------

    @Test
    void recoversFiringStateOnConstructionSoAContinuingBreachDoesNotDuplicate() {
        stubFind(List.of(firingDoc("64b7f00000000000000000aa",
                "ups-input-voltage-low", "ups-1", "input_voltage", 2.0, "2026-09-10T07:55:00Z")));

        evaluator(VOLTAGE_LOW).evaluate(reading("ups-1", "input_voltage", 1.5)); // still breaching

        verify(events, never()).insertOne(any(Document.class));
        verify(events, times(1)).updateOne(any(Bson.class), any(Bson.class)); // lastValue only
        verifyNoInteractions(wsHandler);
        assertTrue(webhook.events.isEmpty());
    }

    @Test
    void aRecoveredFiringEventResolvesItsOwnPersistedDocument() {
        stubFind(List.of(firingDoc("64b7f00000000000000000aa",
                "ups-input-voltage-low", "ups-1", "input_voltage", 2.0, "2026-09-10T07:55:00Z")));

        evaluator(VOLTAGE_LOW).evaluate(reading("ups-1", "input_voltage", 231.0)); // CLEAR

        ArgumentCaptor<Bson> filter = ArgumentCaptor.forClass(Bson.class);
        verify(events).updateOne(filter.capture(), any(Bson.class));
        assertTrue(filter.getValue().toBsonDocument().toJson().contains("64b7f00000000000000000aa"));

        AlertEvent resolved = webhook.events.get(webhook.events.size() - 1);
        assertEquals("resolved", resolved.state());
        assertEquals("64b7f00000000000000000aa", resolved.id());
        assertEquals("2026-09-10T07:55:00Z", resolved.startedAt(), "preserved from the recovered doc");
    }

    @Test
    void ambiguousDuplicateFiringEventsForOneDedupKeyFailConstruction() {
        stubFind(List.of(
                firingDoc("64b7f000000000000000aa01",
                        "ups-input-voltage-low", "ups-1", "input_voltage", 2.0, "2026-09-10T07:50:00Z"),
                firingDoc("64b7f000000000000000aa02",
                        "ups-input-voltage-low", "ups-1", "input_voltage", 3.0, "2026-09-10T07:55:00Z")));

        assertThrows(IllegalStateException.class, () -> evaluator(VOLTAGE_LOW));
    }

    // ------------------------------------------------------------------
    // Slice 12: failure containment — no phantom state, no premature side effects
    // ------------------------------------------------------------------

    @Test
    void aThrowingWebhookDoesNotBreakEvaluationAndSideEffectsStillHappen() {
        AlertWebhook throwing = e -> {
            throw new RuntimeException("connection refused");
        };
        AlertEvaluator evaluator = new AlertEvaluator(
                events, List.of(VOLTAGE_LOW), devices, wsHandler, throwing, clock());

        evaluator.evaluate(reading("ups-1", "input_voltage", 2.1)); // must not throw

        verify(events).insertOne(any(Document.class));
        verify(wsHandler).broadcast(any(AlertMessage.class));
    }

    @Test
    void aDbInsertFailureLeavesNoPhantomFiringStateAndEmitsNoSideEffects() {
        when(events.insertOne(any(Document.class)))
                .thenThrow(new IllegalStateException("write failed"))
                .thenAnswer(inv -> insertResult("64b7f0000000000000000042"));

        AlertEvaluator evaluator = evaluator(VOLTAGE_LOW);
        evaluator.evaluate(reading("ups-1", "input_voltage", 2.1)); // insert throws -> contained

        verifyNoInteractions(wsHandler);
        assertTrue(webhook.events.isEmpty());

        evaluator.evaluate(reading("ups-1", "input_voltage", 2.0)); // still not firing -> retries insert
        verify(events, times(2)).insertOne(any(Document.class));
        assertEquals(1, webhook.events.size(), "exactly one firing event once the write succeeds");
    }

    @Test
    void aResolveWriteFailureKeepsTheAlertFiringAndEmitsNoResolvedSideEffects() {
        doThrow(new IllegalStateException("write failed"))
                .when(events).updateOne(any(Bson.class), any(Bson.class));

        AlertEvaluator evaluator = evaluator(VOLTAGE_LOW);
        evaluator.evaluate(reading("ups-1", "input_voltage", 2.1));    // FIRE
        evaluator.evaluate(reading("ups-1", "input_voltage", 231.0));  // CLEAR write throws -> contained

        verify(wsHandler, times(1)).broadcast(any(AlertMessage.class)); // firing only
        assertEquals(1, webhook.events.size());
        assertEquals("firing", webhook.events.get(0).state());
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private static Document firingDoc(String id, String ruleId, String deviceId, String channel,
            double value, String startedAt) {
        return new Document("_id", new ObjectId(id))
                .append("ruleId", ruleId)
                .append("deviceId", deviceId)
                .append("channel", channel)
                .append("severity", "critical")
                .append("state", "firing")
                .append("triggeredValue", value)
                .append("lastValue", value)
                .append("startedAt", java.util.Date.from(Instant.parse(startedAt)));
    }

    private AlertEvaluator evaluator(AlertRule... rules) {
        return new AlertEvaluator(events, List.of(rules), devices, wsHandler, webhook, clock());
    }

    private Supplier<Instant> clock() {
        return () -> clockReadings.get(Math.min(clockIndex.getAndIncrement(), clockReadings.size() - 1));
    }

    private void stubFind(List<Document> firingDocs) {
        FindIterable<Document> iterable = mock(FindIterable.class);
        doAnswer(inv -> {
            Consumer<Document> consumer = inv.getArgument(0);
            firingDocs.forEach(consumer);
            return null;
        }).when(iterable).forEach(any(Consumer.class));
        when(events.find(any(Bson.class))).thenReturn(iterable);
    }

    private static InsertOneResult insertResult(String hex) {
        InsertOneResult result = mock(InsertOneResult.class);
        when(result.getInsertedId()).thenReturn(new org.bson.BsonObjectId(new ObjectId(hex)));
        return result;
    }

    private static SensorReading reading(String deviceId, String channel, Object value) {
        return new SensorReading(deviceId, channel, value, "x", "2026-09-10T08:00:00Z");
    }

    private static Document deviceDoc(String deviceId, String kind, String channel) {
        return new Document("deviceId", deviceId).append("name", deviceId).append("kind", kind)
                .append("location", "Server Room")
                .append("channels", List.of(new Document("channel", channel).append("unit", "x")));
    }

    /** Records dispatched transitions; models the real non-blocking, never-throwing contract. */
    private static final class RecordingWebhook implements AlertWebhook {
        final List<AlertEvent> events = new CopyOnWriteArrayList<>();

        @Override
        public void dispatch(AlertEvent event) {
            events.add(event);
        }
    }
}
