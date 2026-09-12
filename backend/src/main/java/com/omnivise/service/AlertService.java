package com.omnivise.service;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Optional;

import org.bson.Document;
import org.bson.conversions.Bson;
import org.bson.types.ObjectId;

import com.mongodb.ReadConcern;
import com.mongodb.TransactionOptions;
import com.mongodb.WriteConcern;
import com.mongodb.client.ClientSession;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.mongodb.client.model.FindOneAndUpdateOptions;
import com.mongodb.client.model.Filters;
import com.mongodb.client.model.ReturnDocument;
import com.mongodb.client.model.Updates;
import com.mongodb.client.result.UpdateResult;
import com.omnivise.mapper.AlertEventMapper;
import com.omnivise.model.AlertEvent;

/** MongoDB persistence boundary for alert transitions and REST snapshots. */
public class AlertService {

    public static final String WATERMARK_HEADER = "X-Alert-Watermark";
    static final Document SORT_NEWEST_FIRST = new Document("startedAt", -1).append("_id", -1);

    private static final String GLOBAL_SEQUENCE_ID = "global";
    private static final TransactionOptions TRANSACTION_OPTIONS = TransactionOptions.builder()
            .readConcern(ReadConcern.SNAPSHOT)
            .writeConcern(WriteConcern.MAJORITY)
            .build();

    private final MongoClient mongoClient;
    private final MongoCollection<Document> events;
    private final MongoCollection<Document> sequences;

    public record Snapshot(List<AlertEvent> events, long watermark) {
        public Snapshot {
            events = List.copyOf(events);
            if (watermark < 0) {
                throw new IllegalArgumentException("watermark must be nonnegative");
            }
        }
    }

    public AlertService(String mongoUri, String database) {
        this.mongoClient = MongoClients.create(mongoUri);
        MongoDatabase db = mongoClient.getDatabase(database);
        this.events = db.getCollection("alert_events");
        this.sequences = db.getCollection("alert_sequences");
        System.out.println("✅ MongoDB connected: " + database + ".alert_events");
    }

    /** Test seam with explicit client and collections. */
    AlertService(MongoClient mongoClient, MongoCollection<Document> events,
            MongoCollection<Document> sequences) {
        this.mongoClient = mongoClient;
        this.events = events;
        this.sequences = sequences;
    }

    /** Inserts a firing transition and allocates its sequence atomically. */
    public AlertEvent insertFiring(AlertEvent pending) {
        try (ClientSession session = mongoClient.startSession()) {
            return session.withTransaction(() -> {
                long sequence = nextSequence(session);
                AlertEvent persisted = new AlertEvent(new ObjectId().toHexString(), sequence,
                        pending.ruleId(), pending.deviceId(), pending.channel(), pending.severity(),
                        AlertEvent.STATE_FIRING, pending.triggeredValue(), pending.lastValue(),
                        pending.startedAt(), null);
                events.insertOne(session, AlertEventMapper.toDocument(persisted));
                return persisted;
            }, TRANSACTION_OPTIONS);
        }
    }

    /** Resolves exactly the expected firing version, or returns empty on a stale CAS. */
    public Optional<AlertEvent> resolve(AlertEvent current, double lastValue, String resolvedAt) {
        try (ClientSession session = mongoClient.startSession()) {
            try {
                return Optional.of(session.withTransaction(() -> {
                    long sequence = nextSequence(session);
                    UpdateResult result = events.updateOne(session,
                            Filters.and(
                                    Filters.eq("_id", new ObjectId(current.id())),
                                    Filters.eq("state", AlertEvent.STATE_FIRING),
                                    expectedSequence(current.sequence())),
                            Updates.combine(
                                    Updates.set("state", AlertEvent.STATE_RESOLVED),
                                    Updates.set("sequence", sequence),
                                    Updates.set("lastValue", lastValue),
                                    Updates.set("resolvedAt", Date.from(Instant.parse(resolvedAt)))));
                    if (result.getMatchedCount() != 1) {
                        throw new StaleAlertException();
                    }
                    return new AlertEvent(current.id(), sequence, current.ruleId(), current.deviceId(),
                            current.channel(), current.severity(), AlertEvent.STATE_RESOLVED,
                            current.triggeredValue(), lastValue, current.startedAt(), resolvedAt);
                }, TRANSACTION_OPTIONS));
            } catch (StaleAlertException e) {
                return Optional.empty();
            }
        }
    }

    /** Updates a non-transition value only if the in-memory event is still current. */
    public boolean updateLastValue(AlertEvent current, double lastValue) {
        UpdateResult result = events.updateOne(
                Filters.and(
                        Filters.eq("_id", new ObjectId(current.id())),
                        Filters.eq("state", AlertEvent.STATE_FIRING),
                        expectedSequence(current.sequence())),
                Updates.set("lastValue", lastValue));
        return result.getMatchedCount() == 1;
    }

    /** Returns items and the global watermark from one MongoDB snapshot. */
    public Snapshot findSnapshot(AlertQuery query) {
        try (ClientSession session = mongoClient.startSession()) {
            return session.withTransaction(() -> {
                List<AlertEvent> result = new ArrayList<>();
                events.find(session, buildFilter(query.state(), query.severity(), query.deviceId()))
                        .sort(SORT_NEWEST_FIRST)
                        .limit(query.limit())
                        .forEach(doc -> result.add(AlertEventMapper.fromDocument(doc)));
                Document counter = sequences.find(session, Filters.eq("_id", GLOBAL_SEQUENCE_ID)).first();
                return new Snapshot(result, counter == null ? 0L : sequenceValue(counter));
            }, TRANSACTION_OPTIONS);
        }
    }

    /** Used once at evaluator startup, before the Change Stream thread starts. */
    public List<AlertEvent> findFiring() {
        List<AlertEvent> result = new ArrayList<>();
        events.find(Filters.eq("state", AlertEvent.STATE_FIRING))
                .forEach(doc -> result.add(AlertEventMapper.fromDocument(doc)));
        return result;
    }

    private long nextSequence(ClientSession session) {
        Document counter = sequences.findOneAndUpdate(
                session,
                Filters.eq("_id", GLOBAL_SEQUENCE_ID),
                Updates.inc("value", 1L),
                new FindOneAndUpdateOptions().upsert(true).returnDocument(ReturnDocument.AFTER));
        if (counter == null) {
            throw new IllegalStateException("alert sequence allocation returned no value");
        }
        return sequenceValue(counter);
    }

    private static long sequenceValue(Document counter) {
        Object value = counter.get("value");
        if (value instanceof Byte || value instanceof Short
                || value instanceof Integer || value instanceof Long) {
            Number number = (Number) value;
            long sequence = number.longValue();
            if (sequence >= 0) {
                return sequence;
            }
        }
        throw new IllegalStateException("invalid global alert sequence: " + value);
    }

    private static Bson expectedSequence(long sequence) {
        if (sequence == 0) {
            return Filters.or(Filters.eq("sequence", 0L), Filters.exists("sequence", false));
        }
        return Filters.eq("sequence", sequence);
    }

    static Document buildFilter(String state, String severity, String deviceId) {
        Document filter = new Document();
        if (state != null) {
            filter.append("state", state);
        }
        if (severity != null) {
            filter.append("severity", severity);
        }
        if (deviceId != null) {
            filter.append("deviceId", deviceId);
        }
        return filter;
    }

    private static final class StaleAlertException extends RuntimeException {
    }
}
