package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

import org.bson.Document;
import org.bson.conversions.Bson;
import org.bson.types.ObjectId;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;

import com.mongodb.TransactionOptions;
import com.mongodb.ReadConcern;
import com.mongodb.client.ClientSession;
import com.mongodb.client.FindIterable;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.TransactionBody;
import com.mongodb.client.model.FindOneAndUpdateOptions;
import com.mongodb.client.result.UpdateResult;
import com.omnivise.model.AlertEvent;

@SuppressWarnings("unchecked")
class AlertServiceTest {

    private final MongoClient client = mock(MongoClient.class);
    private final ClientSession session = mock(ClientSession.class);
    private final MongoCollection<Document> events = mock(MongoCollection.class);
    private final MongoCollection<Document> sequences = mock(MongoCollection.class);
    private final AtomicLong nextSequence = new AtomicLong();
    private AlertService service;

    @BeforeEach
    void setUp() {
        when(client.startSession()).thenReturn(session);
        when(session.withTransaction(any(TransactionBody.class), any(TransactionOptions.class)))
                .thenAnswer(inv -> ((TransactionBody<?>) inv.getArgument(0)).execute());
        when(sequences.findOneAndUpdate(any(ClientSession.class), any(Bson.class), any(Bson.class),
                any(FindOneAndUpdateOptions.class)))
                .thenAnswer(inv -> new Document("_id", "global")
                        .append("value", nextSequence.incrementAndGet()));
        service = new AlertService(client, events, sequences);
    }

    @Test
    void transitionSequenceIsAllocatedAndPersistedInTheSameSession() {
        AlertEvent firing = service.insertFiring(pending());
        when(events.updateOne(any(ClientSession.class), any(Bson.class), any(Bson.class)))
                .thenReturn(UpdateResult.acknowledged(1, 1L, null));

        AlertEvent resolved = service.resolve(firing, 231.0, "2026-09-10T08:01:00Z").orElseThrow();

        assertEquals(1L, firing.sequence());
        assertEquals(2L, resolved.sequence());
        ArgumentCaptor<Document> inserted = ArgumentCaptor.forClass(Document.class);
        verify(events).insertOne(org.mockito.ArgumentMatchers.same(session), inserted.capture());
        assertEquals(1L, inserted.getValue().getLong("sequence"));

        ArgumentCaptor<Bson> update = ArgumentCaptor.forClass(Bson.class);
        verify(events).updateOne(org.mockito.ArgumentMatchers.same(session), any(Bson.class), update.capture());
        assertTrue(update.getValue().toBsonDocument().toJson().contains("\"sequence\": 2"));
        verify(sequences, times(2)).findOneAndUpdate(
                org.mockito.ArgumentMatchers.same(session), any(Bson.class), any(Bson.class),
                any(FindOneAndUpdateOptions.class));
    }

    @Test
    void insertFailureEscapesTheTransactionAndCannotReturnAPersistedEvent() {
        org.mockito.Mockito.doThrow(new IllegalStateException("insert failed"))
                .when(events).insertOne(any(ClientSession.class), any(Document.class));

        assertThrows(IllegalStateException.class, () -> service.insertFiring(pending()));
        verify(sequences).findOneAndUpdate(org.mockito.ArgumentMatchers.same(session),
                any(Bson.class), any(Bson.class), any(FindOneAndUpdateOptions.class));
    }

    @Test
    void resolveUsesIdStateAndSequenceCasAndReturnsEmptyOnMiss() {
        when(events.updateOne(any(ClientSession.class), any(Bson.class), any(Bson.class)))
                .thenReturn(UpdateResult.acknowledged(0, 0L, null));
        AlertEvent current = firing(7L);

        Optional<AlertEvent> result = service.resolve(current, 231.0, "2026-09-10T08:01:00Z");

        assertTrue(result.isEmpty());
        ArgumentCaptor<Bson> filter = ArgumentCaptor.forClass(Bson.class);
        verify(events).updateOne(org.mockito.ArgumentMatchers.same(session), filter.capture(), any(Bson.class));
        String filterJson = filter.getValue().toBsonDocument().toJson();
        assertTrue(filterJson.contains(current.id()));
        assertTrue(filterJson.contains("firing"));
        assertTrue(filterJson.contains("\"sequence\": 7"));
    }

    @Test
    void legacySequenceZeroCasAlsoMatchesAMissingSequenceField() {
        when(events.updateOne(any(ClientSession.class), any(Bson.class), any(Bson.class)))
                .thenReturn(UpdateResult.acknowledged(0, 0L, null));

        service.resolve(firing(0L), 231.0, "2026-09-10T08:01:00Z");

        ArgumentCaptor<Bson> filter = ArgumentCaptor.forClass(Bson.class);
        verify(events).updateOne(any(ClientSession.class), filter.capture(), any(Bson.class));
        String json = filter.getValue().toBsonDocument().toJson();
        assertTrue(json.contains("$exists"));
        assertTrue(json.contains("false"));
    }

    @Test
    void repeatedValueUpdateDoesNotAllocateASequence() {
        when(events.updateOne(any(Bson.class), any(Bson.class)))
                .thenReturn(UpdateResult.acknowledged(1, 1L, null));

        assertTrue(service.updateLastValue(firing(4L), 1.5));

        verify(events).updateOne(any(Bson.class), any(Bson.class));
        verify(sequences, times(0)).findOneAndUpdate(any(ClientSession.class), any(Bson.class),
                any(Bson.class), any(FindOneAndUpdateOptions.class));
    }

    @Test
    void snapshotReadsItemsAndWatermarkThroughTheSameSessionAndKeepsArrayPayload() {
        FindIterable<Document> eventFind = iterable(List.of(eventDoc(11L)));
        FindIterable<Document> sequenceFind = iterable(List.of(new Document("_id", "global").append("value", 15L)));
        when(events.find(any(ClientSession.class), any(Bson.class))).thenReturn(eventFind);
        when(sequences.find(any(ClientSession.class), any(Bson.class))).thenReturn(sequenceFind);
        AlertQuery query = assertInstanceOf(AlertQuery.Valid.class,
                AlertQuery.parse("firing", null, null, "25")).query();

        AlertService.Snapshot snapshot = service.findSnapshot(query);

        assertEquals(15L, snapshot.watermark());
        assertEquals(List.of(11L), snapshot.events().stream().map(AlertEvent::sequence).toList());
        ArgumentCaptor<TransactionOptions> transactionOptions = ArgumentCaptor.forClass(TransactionOptions.class);
        verify(session).withTransaction(any(TransactionBody.class), transactionOptions.capture());
        assertEquals(ReadConcern.SNAPSHOT, transactionOptions.getValue().getReadConcern());
        InOrder order = inOrder(events, sequences);
        order.verify(events).find(org.mockito.ArgumentMatchers.same(session), any(Bson.class));
        order.verify(sequences).find(org.mockito.ArgumentMatchers.same(session), any(Bson.class));
        verify(eventFind).sort(AlertService.SORT_NEWEST_FIRST);
        verify(eventFind).limit(25);
    }

    @Test
    void snapshotWithoutACounterHasDecimalZeroWatermark() {
        FindIterable<Document> emptyEvents = iterable(List.of());
        FindIterable<Document> emptySequences = iterable(List.of());
        when(events.find(any(ClientSession.class), any(Bson.class))).thenReturn(emptyEvents);
        when(sequences.find(any(ClientSession.class), any(Bson.class))).thenReturn(emptySequences);
        AlertQuery query = assertInstanceOf(AlertQuery.Valid.class,
                AlertQuery.parse(null, null, null, null)).query();

        AlertService.Snapshot snapshot = service.findSnapshot(query);

        assertEquals(0L, snapshot.watermark());
        assertEquals("0", Long.toString(snapshot.watermark()));
        assertEquals(List.of(), snapshot.events());
    }

    @Test
    void allQueryFiltersAreCombined() {
        assertEquals(new Document("state", "resolved").append("severity", "warning")
                        .append("deviceId", "rack-a1"),
                AlertService.buildFilter("resolved", "warning", "rack-a1"));
    }

    private <T> FindIterable<T> iterable(List<T> values) {
        FindIterable<T> iterable = mock(FindIterable.class);
        when(iterable.sort(any(Bson.class))).thenReturn(iterable);
        when(iterable.limit(anyInt())).thenReturn(iterable);
        when(iterable.first()).thenReturn(values.isEmpty() ? null : values.getFirst());
        doAnswer(inv -> {
            Consumer<T> consumer = inv.getArgument(0);
            values.forEach(consumer);
            return null;
        }).when(iterable).forEach(any(Consumer.class));
        return iterable;
    }

    private static AlertEvent pending() {
        return new AlertEvent(null, 0L, "ups-input-voltage-low", "ups-1", "input_voltage",
                "critical", "firing", 2.1, 2.1, "2026-09-10T08:00:00Z", null);
    }

    private static AlertEvent firing(long sequence) {
        return new AlertEvent("64b7f0000000000000000001", sequence, "ups-input-voltage-low",
                "ups-1", "input_voltage", "critical", "firing", 2.1, 2.1,
                "2026-09-10T08:00:00Z", null);
    }

    private static Document eventDoc(long sequence) {
        return new Document("_id", new ObjectId("64b7f0000000000000000001"))
                .append("sequence", sequence)
                .append("ruleId", "ups-input-voltage-low")
                .append("deviceId", "ups-1")
                .append("channel", "input_voltage")
                .append("severity", "critical")
                .append("state", "firing")
                .append("triggeredValue", 2.1)
                .append("lastValue", 2.1)
                .append("startedAt", Date.from(Instant.parse("2026-09-10T08:00:00Z")));
    }
}
