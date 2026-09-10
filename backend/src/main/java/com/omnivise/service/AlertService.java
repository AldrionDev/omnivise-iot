package com.omnivise.service;

import java.util.ArrayList;
import java.util.List;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.omnivise.mapper.AlertEventMapper;
import com.omnivise.model.AlertEvent;

/**
 * Read access to the {@code alert_events} collection for {@code GET /api/alerts}
 * and {@code GET /api/alerts/active} (issue #73).
 *
 * <p>The write path ({@code AlertEvaluator}) owns state transitions; this is
 * query-only. Filtering is by the already-validated {@code state}/{@code
 * severity}/{@code deviceId} (see {@link AlertQuery}); results are newest first
 * by {@code startedAt} with a stable {@code _id} tie-breaker, capped at the
 * query {@code limit}. Document mapping is delegated to {@link AlertEventMapper}.
 */
public class AlertService {

    /** Newest first: {@code startedAt} descending, {@code _id} descending as a stable tie-breaker. */
    static final Document SORT_NEWEST_FIRST = new Document("startedAt", -1).append("_id", -1);

    private final MongoCollection<Document> collection;

    /**
     * Connects to MongoDB and resolves the {@code alert_events} collection.
     *
     * @param mongoUri MongoDB connection URI
     * @param database database name (e.g. {@code omnivise_iot})
     */
    public AlertService(String mongoUri, String database) {
        MongoClient mongoClient = MongoClients.create(mongoUri);
        MongoDatabase db = mongoClient.getDatabase(database);
        this.collection = db.getCollection("alert_events");
        System.out.println("✅ MongoDB connected: " + database + ".alert_events");
    }

    /** Test seam: build the service directly on a collection. */
    AlertService(MongoCollection<Document> collection) {
        this.collection = collection;
    }

    /**
     * The {@code alert_events} collection, shared with {@code AlertEvaluator} so
     * the write and read paths use one handle (mirrors
     * {@code SensorService#getCollection}).
     */
    public MongoCollection<Document> getCollection() {
        return collection;
    }

    /**
     * Alert events matching the validated query, newest first, capped at
     * {@link AlertQuery#limit()}.
     */
    public List<AlertEvent> find(AlertQuery query) {
        List<AlertEvent> events = new ArrayList<>();
        collection.find(buildFilter(query.state(), query.severity(), query.deviceId()))
                .sort(SORT_NEWEST_FIRST)
                .limit(query.limit())
                .forEach(doc -> events.add(AlertEventMapper.fromDocument(doc)));
        return events;
    }

    /**
     * Builds the MongoDB filter for {@link #find}. Each non-null component is an
     * equality match on its field; a {@code null} component is "no filter on
     * that field". Package-private so the filter contract can be unit-tested
     * without a live MongoDB.
     */
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
}
