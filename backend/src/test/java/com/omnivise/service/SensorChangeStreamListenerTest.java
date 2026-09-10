package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.after;
import static org.mockito.Mockito.atLeast;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.clearInvocations;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.timeout;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;

import org.bson.Document;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import com.mongodb.MongoException;
import com.mongodb.client.ChangeStreamIterable;
import com.mongodb.client.MongoChangeStreamCursor;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.model.changestream.ChangeStreamDocument;
import com.mongodb.client.model.changestream.OperationType;
import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.SensorReading;

/**
 * Recovery behaviour of the MongoDB Change Stream listener (issue #56).
 *
 * <p>All MongoDB interaction is mocked. The tests drive the real supervision
 * thread and a fake {@link SensorChangeStreamListener.Sleeper} so no wall-clock
 * waiting happens. A MongoDB error code 11600 stands in for the
 * {@code MongoNodeIsRecoveringException} / {@code InterruptedAtShutdown}
 * conditions seen during a replica-set fail-over.
 *
 * <p>Mockito note: every mock and prepared return value is fully built on its
 * own statement before it is handed to {@code when(...).thenReturn(...)}. Never
 * call a helper that stubs a mock inside another unfinished {@code when(...)}.
 */
@SuppressWarnings("unchecked")
class SensorChangeStreamListenerTest {

    private static final int RECOVERING = 11600;

    private final MongoCollection<Document> collection = mock(MongoCollection.class);
    private final WebSocketHandler wsHandler = mock(WebSocketHandler.class);
    private final List<Long> sleeps = new CopyOnWriteArrayList<>();

    private SensorChangeStreamListener listener;

    @AfterEach
    void tearDown() {
        if (listener != null) {
            listener.stop();
        }
    }

    // ------------------------------------------------------------------
    // Recovery after a transient interruption
    // ------------------------------------------------------------------

    @Test
    void resumesConsumptionAfterRecoveringException() {
        CountDownLatch park = new CountDownLatch(1);

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> failing = mockCursor();
        when(failing.hasNext()).thenThrow(new MongoException(RECOVERING, "node is recovering"));

        ChangeStreamDocument<Document> insertEvent = insertEvent(sampleDoc());
        MongoChangeStreamCursor<ChangeStreamDocument<Document>> healthy = parkingCursor(park);
        when(healthy.hasNext()).thenReturn(true).thenAnswer(inv -> awaitThenFalse(park));
        when(healthy.next()).thenReturn(insertEvent);

        ChangeStreamIterable<Document> iterFailing = iterableReturning(failing);
        ChangeStreamIterable<Document> iterHealthy = iterableReturning(healthy);
        when(collection.watch()).thenReturn(iterFailing, iterHealthy);

        listener = newListener(5, 20, recordingSleeper());
        listener.start();

        ArgumentCaptor<SensorReading> captor = ArgumentCaptor.forClass(SensorReading.class);
        verify(wsHandler, timeout(3_000)).broadcast(captor.capture());

        SensorReading delivered = captor.getValue();
        assertEquals("rack-a1", delivered.deviceId());
        assertEquals("intake_temp", delivered.channel());
        assertEquals(25.5, delivered.value());
        assertEquals("°C", delivered.unit());
        assertEquals("2026-09-10T08:00:00Z", delivered.timestamp());

        verify(collection, atLeast(2)).watch();
        assertFalse(sleeps.isEmpty(), "a bounded wait must precede the reopen");
        assertTrue(sleeps.stream().allMatch(d -> d >= 5 && d <= 20), "wait must stay within bounds");
    }

    @Test
    void genericRuntimeExceptionDoesNotKillTheListener() {
        CountDownLatch park = new CountDownLatch(1);

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> failing = mockCursor();
        when(failing.hasNext()).thenThrow(new IllegalStateException("boom"));

        ChangeStreamDocument<Document> insertEvent = insertEvent(sampleDoc());
        MongoChangeStreamCursor<ChangeStreamDocument<Document>> healthy = parkingCursor(park);
        when(healthy.hasNext()).thenReturn(true).thenAnswer(inv -> awaitThenFalse(park));
        when(healthy.next()).thenReturn(insertEvent);

        ChangeStreamIterable<Document> iterFailing = iterableReturning(failing);
        ChangeStreamIterable<Document> iterHealthy = iterableReturning(healthy);
        when(collection.watch()).thenReturn(iterFailing, iterHealthy);

        listener = newListener(5, 20, recordingSleeper());
        listener.start();

        verify(wsHandler, timeout(3_000)).broadcast(any(SensorReading.class));
        verify(collection, atLeast(2)).watch();
    }

    // ------------------------------------------------------------------
    // Bounded, progressive backoff (issue #56: "no tight loops")
    // ------------------------------------------------------------------

    @Test
    void backoffProgressesAndCapsWhileTheStreamKeepsFailing() {
        MongoChangeStreamCursor<ChangeStreamDocument<Document>> failing = mockCursor();
        when(failing.hasNext()).thenThrow(new MongoException(RECOVERING, "node is recovering"));

        ChangeStreamIterable<Document> iterable = iterableReturning(failing);
        when(collection.watch()).thenReturn(iterable);

        // Sleeper records each delay and aborts the loop after 7 attempts.
        SensorChangeStreamListener.Sleeper capped = millis -> {
            sleeps.add(millis);
            if (sleeps.size() >= 7) {
                throw new InterruptedException("test: stop after 7 attempts");
            }
        };

        listener = newListener(10, 80, capped);
        listener.start();

        await(() -> sleeps.size() >= 7, 3_000);

        assertEquals(
                List.of(10L, 20L, 40L, 80L, 80L, 80L, 80L),
                new ArrayList<>(sleeps).subList(0, 7),
                "opening a cursor must NOT reset the backoff; it only advances and caps");
    }

    @Test
    void backoffResetsOnlyAfterAHealthyDelivery() {
        CountDownLatch park = new CountDownLatch(1);

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> failA = mockCursor();
        when(failA.hasNext()).thenThrow(new MongoException(RECOVERING, "recovering"));

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> failB = mockCursor();
        when(failB.hasNext()).thenThrow(new MongoException(RECOVERING, "recovering"));

        // Opens, delivers one event (=> healthy => reset), then fails again.
        ChangeStreamDocument<Document> insertEvent = insertEvent(sampleDoc());
        MongoChangeStreamCursor<ChangeStreamDocument<Document>> healthyThenFail = mockCursor();
        when(healthyThenFail.hasNext())
                .thenReturn(true)
                .thenThrow(new MongoException(RECOVERING, "recovering"));
        when(healthyThenFail.next()).thenReturn(insertEvent);

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> parked = parkingCursor(park);
        when(parked.hasNext()).thenAnswer(inv -> awaitThenFalse(park));

        ChangeStreamIterable<Document> iterA = iterableReturning(failA);
        ChangeStreamIterable<Document> iterB = iterableReturning(failB);
        ChangeStreamIterable<Document> iterC = iterableReturning(healthyThenFail);
        ChangeStreamIterable<Document> iterD = iterableReturning(parked);
        when(collection.watch()).thenReturn(iterA, iterB, iterC, iterD);

        listener = newListener(10, 80, recordingSleeper());
        listener.start();

        verify(wsHandler, timeout(3_000)).broadcast(any(SensorReading.class));
        await(() -> sleeps.size() >= 3, 2_000);

        assertEquals(
                List.of(10L, 20L, 10L),
                new ArrayList<>(sleeps).subList(0, 3),
                "delay must progress while failing (10, 20) and reset to base (10) after a delivered event");
    }

    // ------------------------------------------------------------------
    // Clean shutdown and single-consumer guarantees
    // ------------------------------------------------------------------

    @Test
    void stopClosesTheCursorAndEndsTheThreadPromptly() {
        CountDownLatch park = new CountDownLatch(1);

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> healthy = parkingCursor(park);
        when(healthy.hasNext()).thenAnswer(inv -> awaitThenFalse(park));

        ChangeStreamIterable<Document> iterable = iterableReturning(healthy);
        when(collection.watch()).thenReturn(iterable);

        listener = newListener(1_000, 30_000, recordingSleeper());
        listener.start();
        verify(collection, timeout(2_000)).watch();

        long startNanos = System.nanoTime();
        listener.stop();
        long elapsedMs = (System.nanoTime() - startNanos) / 1_000_000L;

        assertTrue(elapsedMs < 4_000, "stop() must return well within the join timeout, took " + elapsedMs + " ms");
        verify(healthy, atLeastOnce()).close();
        assertFalse(listener.isListenerAlive(), "worker thread must be gone after stop()");

        clearInvocations(collection);
        verify(collection, after(300).never()).watch(); // no further reopen attempts once stopped
    }

    @Test
    void callingStartTwiceKeepsASingleConsumer() {
        CountDownLatch park = new CountDownLatch(1);

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> healthy = parkingCursor(park);
        when(healthy.hasNext()).thenAnswer(inv -> awaitThenFalse(park));

        ChangeStreamIterable<Document> iterable = iterableReturning(healthy);
        when(collection.watch()).thenReturn(iterable);

        listener = newListener(1_000, 30_000, recordingSleeper());
        listener.start();
        verify(collection, timeout(2_000)).watch();

        listener.start(); // must be a no-op

        verify(collection, after(300).times(1)).watch();
        assertTrue(listener.isListenerAlive());
    }

    @Test
    void listenerCanBeRestartedAfterStop() {
        CountDownLatch firstPark = new CountDownLatch(1);
        CountDownLatch secondPark = new CountDownLatch(1);

        MongoChangeStreamCursor<ChangeStreamDocument<Document>> first = parkingCursor(firstPark);
        when(first.hasNext()).thenAnswer(inv -> awaitThenFalse(firstPark));

        ChangeStreamDocument<Document> insertEvent = insertEvent(sampleDoc());
        MongoChangeStreamCursor<ChangeStreamDocument<Document>> second = parkingCursor(secondPark);
        when(second.hasNext()).thenReturn(true).thenAnswer(inv -> awaitThenFalse(secondPark));
        when(second.next()).thenReturn(insertEvent);

        ChangeStreamIterable<Document> iterFirst = iterableReturning(first);
        ChangeStreamIterable<Document> iterSecond = iterableReturning(second);
        when(collection.watch()).thenReturn(iterFirst, iterSecond);

        listener = newListener(1_000, 30_000, recordingSleeper());
        listener.start();
        verify(collection, timeout(2_000)).watch();

        listener.stop();
        assertFalse(listener.isListenerAlive());

        listener.start();
        verify(wsHandler, timeout(3_000)).broadcast(any(SensorReading.class));
        verify(collection, atLeast(2)).watch();
    }

    // ------------------------------------------------------------------
    // Helpers — each builds a fully-stubbed value; never call inside a
    // still-open when(...).thenReturn(...).
    // ------------------------------------------------------------------

    private SensorChangeStreamListener newListener(long baseMs, long maxMs, SensorChangeStreamListener.Sleeper sleeper) {
        return new SensorChangeStreamListener(collection, wsHandler, baseMs, maxMs, sleeper);
    }

    private SensorChangeStreamListener.Sleeper recordingSleeper() {
        return millis -> sleeps.add(millis);
    }

    private MongoChangeStreamCursor<ChangeStreamDocument<Document>> mockCursor() {
        return mock(MongoChangeStreamCursor.class);
    }

    private MongoChangeStreamCursor<ChangeStreamDocument<Document>> parkingCursor(CountDownLatch park) {
        MongoChangeStreamCursor<ChangeStreamDocument<Document>> cursor = mock(MongoChangeStreamCursor.class);
        doAnswer(inv -> {
            park.countDown();
            return null;
        }).when(cursor).close();
        return cursor;
    }

    private ChangeStreamIterable<Document> iterableReturning(MongoChangeStreamCursor<ChangeStreamDocument<Document>> cursor) {
        ChangeStreamIterable<Document> iterable = mock(ChangeStreamIterable.class);
        when(iterable.cursor()).thenReturn(cursor);
        return iterable;
    }

    private ChangeStreamDocument<Document> insertEvent(Document fullDocument) {
        ChangeStreamDocument<Document> change = mock(ChangeStreamDocument.class);
        when(change.getOperationType()).thenReturn(OperationType.INSERT);
        when(change.getFullDocument()).thenReturn(fullDocument);
        return change;
    }

    private Document sampleDoc() {
        return new Document("deviceId", "rack-a1")
                .append("channel", "intake_temp")
                .append("value", 25.5)
                .append("unit", "°C")
                .append("timestamp", Date.from(Instant.parse("2026-09-10T08:00:00Z")));
    }

    private static boolean awaitThenFalse(CountDownLatch latch) {
        try {
            latch.await(3, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
        return false;
    }

    private static void await(BooleanSupplier condition, long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (condition.getAsBoolean()) {
                return;
            }
            try {
                Thread.sleep(10);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
        throw new AssertionError("condition not met within " + timeoutMs + " ms");
    }
}
