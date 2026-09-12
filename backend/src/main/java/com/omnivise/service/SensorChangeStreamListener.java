package com.omnivise.service;

import org.bson.Document;

import com.mongodb.MongoException;
import com.mongodb.client.MongoChangeStreamCursor;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.model.changestream.ChangeStreamDocument;
import com.omnivise.handler.WebSocketHandler;
import com.omnivise.mapper.SensorReadingMapper;
import com.omnivise.model.SensorReading;

/**
 * Listens to MongoDB Change Stream events and broadcasts new sensor readings
 * to all connected WebSocket clients in real-time.
 *
 * <p>The listener runs a supervision loop on a single daemon thread. If the
 * Change Stream is terminated by a transient MongoDB topology transition
 * (replica-set fail-over, node stepping down / recovering, socket drop), the
 * loop logs the interruption, waits a bounded, progressively increasing delay
 * and reopens the stream. It keeps retrying until it succeeds or the
 * application asks it to stop.
 *
 * <p>Recovery reopens the stream from "now" — changes written while the stream
 * was down are not replayed. Gap-free recovery would require a persisted resume
 * token and durable oplog retention, which are out of scope for this listener.
 *
 * <p>{@link #start()} and {@link #stop()} are synchronized and {@code stop()}
 * joins the worker thread, so at most one Change Stream consumer is ever active.
 */
public class SensorChangeStreamListener {

    private static final long DEFAULT_BASE_DELAY_MS = 1_000L;
    private static final long DEFAULT_MAX_DELAY_MS = 30_000L;
    private static final long SHUTDOWN_JOIN_MS = 5_000L;

    private final MongoCollection<Document> collection;
    private final WebSocketHandler wsHandler;
    private final AlertEvaluator alertEvaluator;
    private final Backoff backoff;
    private final Sleeper sleeper;

    private volatile Thread listenerThread;
    private volatile boolean running = false;
    private volatile MongoChangeStreamCursor<ChangeStreamDocument<Document>> currentCursor;

    /**
     * Creates a new Change Stream Listener with production retry defaults.
     *
     * @param collection     MongoDB collection to watch for changes
     * @param wsHandler       WebSocket handler for broadcasting data
     * @param alertEvaluator  threshold-rule evaluation run inline for each insert (issue #73)
     */
    public SensorChangeStreamListener(
            MongoCollection<Document> collection,
            WebSocketHandler wsHandler,
            AlertEvaluator alertEvaluator) {
        this(collection, wsHandler, alertEvaluator, DEFAULT_BASE_DELAY_MS, DEFAULT_MAX_DELAY_MS, Thread::sleep);
    }

    /**
     * Test seam: allows tuning the backoff bounds and injecting a fake sleeper so
     * recovery behaviour can be exercised without real waiting.
     */
    SensorChangeStreamListener(
            MongoCollection<Document> collection,
            WebSocketHandler wsHandler,
            AlertEvaluator alertEvaluator,
            long baseDelayMs,
            long maxDelayMs,
            Sleeper sleeper) {
        this.collection = collection;
        this.wsHandler = wsHandler;
        this.alertEvaluator = alertEvaluator;
        this.backoff = new Backoff(baseDelayMs, maxDelayMs);
        this.sleeper = sleeper;
    }

    /**
     * Starts the Change Stream supervision loop on a dedicated daemon thread.
     * A no-op if the listener is already running.
     */
    public synchronized void start() {
        if (listenerThread != null && listenerThread.isAlive()) {
            System.out.println("⚠️ Change Stream listener is already running");
            return;
        }

        running = true;
        currentCursor = null;
        backoff.reset();

        listenerThread = new Thread(this::runLoop, "ChangeStreamListener");
        listenerThread.setDaemon(true);
        listenerThread.start();
    }

    /**
     * Stops the Change Stream listener and waits for the worker thread to finish.
     * Closes the active cursor to unblock a thread parked on the stream, then
     * interrupts and joins it.
     */
    public synchronized void stop() {
        if (!running && (listenerThread == null || !listenerThread.isAlive())) {
            return;
        }

        running = false;

        MongoChangeStreamCursor<?> cursor = currentCursor;
        if (cursor != null) {
            try {
                // Closing from another thread unblocks a worker parked in hasNext().
                cursor.close();
            } catch (RuntimeException ignored) {
                // A close that races with the worker may throw; safe to ignore.
            }
        }

        Thread thread = listenerThread;
        if (thread != null) {
            thread.interrupt();
            try {
                thread.join(SHUTDOWN_JOIN_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

        System.out.println("🛑 Change Stream listener stopped");
    }

    /** Test seam: whether the supervision loop is currently running. */
    boolean isListenerAlive() {
        return running && listenerThread != null && listenerThread.isAlive();
    }

    /**
     * Supervision loop: (re)open the Change Stream, consume it until it ends or
     * throws, then back off and try again until {@link #stop()} is called.
     */
    private void runLoop() {
        System.out.println("👂 MongoDB Change Stream listener started");
        int consecutiveFailures = 0;

        while (running) {
            boolean deliveredThisSession = false;
            try (MongoChangeStreamCursor<ChangeStreamDocument<Document>> cursor = collection.watch().cursor()) {
                currentCursor = cursor;
                System.out.println(consecutiveFailures == 0
                        ? "👂 Change Stream opened"
                        : "👂 Change Stream reopened (after " + consecutiveFailures + " failed attempt(s))");

                // hasNext() blocks until a change is available or the cursor is
                // closed / errored, so this loop never spins while the stream is
                // healthy but idle.
                while (running && cursor.hasNext()) {
                    ChangeStreamDocument<Document> change = cursor.next();

                    if (!deliveredThisSession) {
                        // The stream has demonstrated healthy operation. Only now
                        // is it safe to reset the backoff; an immediately failing
                        // cursor must keep progressing the delay.
                        deliveredThisSession = true;
                        if (consecutiveFailures > 0) {
                            System.out.println("✅ Change Stream recovered after "
                                    + consecutiveFailures + " failed attempt(s)");
                        }
                        consecutiveFailures = 0;
                        backoff.reset();
                    }

                    handleChange(change);
                }
            } catch (Exception e) {
                if (!running) {
                    break;
                }
                consecutiveFailures++;
                logInterruption(e, consecutiveFailures);
            } finally {
                currentCursor = null;
            }

            if (!running) {
                break;
            }

            try {
                long waitedMs = backoff.sleepThenAdvance(sleeper);
                if (running) {
                    System.out.println("⏳ Retrying Change Stream in "
                            + waitedMs + " ms (consecutive failures: " + consecutiveFailures + ")");
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                break;
            }
        }
    }

    private void handleChange(ChangeStreamDocument<Document> change) {
        if (change.getOperationType() == null
                || !"insert".equals(change.getOperationType().getValue())) {
            return;
        }

        Document doc = change.getFullDocument();
        if (doc == null) {
            return;
        }

        SensorReading reading = SensorReadingMapper.fromDocument(doc);
        wsHandler.broadcast(reading);

        System.out.println("📤 Broadcasted: " + reading.deviceId()
                + " | " + reading.channel() + " = " + reading.value() + " " + reading.unit());

        // Threshold alerting runs inline on this thread (issue #73). It is
        // self-contained and non-blocking, but a failure here must never be
        // mistaken for a Change Stream error and trigger the reconnection
        // backoff — so it is caught and contained.
        try {
            alertEvaluator.evaluate(reading);
        } catch (RuntimeException e) {
            System.err.println("⚠️ Alert evaluation raised past its own guard: " + e);
        }
    }

    private void logInterruption(Exception e, int consecutiveFailures) {
        String code = (e instanceof MongoException me) ? " [code " + me.getCode() + "]" : "";
        System.err.println("⚠️ Change Stream interrupted: "
                + e.getClass().getSimpleName() + code
                + " — \"" + e.getMessage() + "\" (attempt #" + consecutiveFailures + " will reopen)");
    }

    /**
     * Bounded exponential backoff. Starts at {@code baseMs}, doubles up to
     * {@code maxMs}, and is reset to base only when the stream proves healthy.
     */
    static final class Backoff {
        private final long baseMs;
        private final long maxMs;
        private long nextMs;

        Backoff(long baseMs, long maxMs) {
            this.baseMs = Math.max(1L, baseMs);
            this.maxMs = Math.max(this.baseMs, maxMs);
            this.nextMs = this.baseMs;
        }

        synchronized void reset() {
            this.nextMs = this.baseMs;
        }

        /**
         * Sleeps for the current delay, then advances it towards {@code maxMs}.
         *
         * @return the delay that was just slept, in milliseconds
         */
        synchronized long sleepThenAdvance(Sleeper sleeper) throws InterruptedException {
            long current = this.nextMs;
            sleeper.sleep(current);
            this.nextMs = Math.min(this.maxMs, this.nextMs * 2);
            return current;
        }
    }

    /** Test seam for the blocking wait between reconnection attempts. */
    @FunctionalInterface
    interface Sleeper {
        void sleep(long millis) throws InterruptedException;
    }
}
