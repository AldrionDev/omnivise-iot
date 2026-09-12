package com.omnivise.service;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.omnivise.mapper.SensorReadingMapper;
import com.omnivise.model.SensorHistory;
import com.omnivise.model.SensorReading;

/**
 * Read access to the {@code sensor_readings} collection.
 *
 * <p>Since issue #70 a reading is keyed by {@code deviceId} + {@code channel};
 * the only query is "latest readings, newest first, optionally filtered by
 * device and/or channel". Document mapping is delegated to the shared
 * {@link SensorReadingMapper}.
 */
public class SensorService {

    /** Sort applied to every "latest readings" query: newest first. */
    static final Document SORT_NEWEST_FIRST = new Document("timestamp", -1);

    private final MongoCollection<Document> collection;

    /**
     * Connects to MongoDB and resolves the {@code sensor_readings} collection.
     *
     * @param mongoUri MongoDB connection URI
     * @param database database name (e.g. {@code omnivise_iot})
     */
    public SensorService(String mongoUri, String database) {
        MongoClient mongoClient = MongoClients.create(mongoUri);
        MongoDatabase db = mongoClient.getDatabase(database);
        this.collection = db.getCollection("sensor_readings");
        System.out.println("✅ MongoDB connected: " + database + ".sensor_readings");
    }

    /**
     * Test seam: build the service directly on a collection, without a live
     * MongoDB connection.
     */
    SensorService(MongoCollection<Document> collection) {
        this.collection = collection;
    }

    /**
     * Latest readings, newest first, optionally filtered by device and/or
     * channel. A {@code null} or blank filter component is treated as "no
     * filter on that field".
     *
     * @param deviceId device id filter, or {@code null}/blank for any device
     * @param channel  channel filter, or {@code null}/blank for any channel
     * @param limit    maximum number of readings to return
     * @return readings sorted by {@code timestamp} descending
     */
    public List<SensorReading> getLatestReadings(String deviceId, String channel, int limit) {
        List<SensorReading> readings = new ArrayList<>();
        collection.find(buildLatestFilter(deviceId, channel))
                .sort(SORT_NEWEST_FIRST)
                .limit(limit)
                .forEach(doc -> readings.add(SensorReadingMapper.fromDocument(doc)));
        return readings;
    }

    /**
     * Builds the MongoDB filter for {@link #getLatestReadings}. Package-private
     * so the filter-construction contract can be unit-tested without a live
     * MongoDB.
     */
    static Document buildLatestFilter(String deviceId, String channel) {
        Document filter = new Document();
        if (deviceId != null && !deviceId.isBlank()) {
            filter.append("deviceId", deviceId);
        }
        if (channel != null && !channel.isBlank()) {
            filter.append("channel", channel);
        }
        return filter;
    }

    /**
     * Builds the down-sampling aggregation pipeline for
     * {@code GET /api/sensors/history} (issue #72): {@code $match} on device +
     * channel + a half-open {@code timestamp} range, {@code $group} into
     * {@code $dateTrunc} buckets with {@code avg}/{@code min}/{@code max} of
     * {@code value}, then {@code $sort} ascending by bucket start.
     *
     * <p>Package-private so the pipeline contract can be unit-tested without a
     * live MongoDB. The stored {@code timestamp} is a BSON {@code Date}, so the
     * range bounds are passed as {@link Date}.
     */
    static List<Document> buildHistoryPipeline(
            String deviceId, String channel, Instant from, Instant to, Bucket bucket) {
        Document range = new Document("$gte", Date.from(from)).append("$lt", Date.from(to));
        Document match = new Document("deviceId", deviceId)
                .append("channel", channel)
                .append("timestamp", range);

        Document dateTrunc = new Document("date", "$timestamp")
                .append("unit", bucket.truncUnit())
                .append("binSize", bucket.binSize());
        Document group = new Document("_id", new Document("$dateTrunc", dateTrunc))
                .append("avg", new Document("$avg", "$value"))
                .append("min", new Document("$min", "$value"))
                .append("max", new Document("$max", "$value"));

        Document sort = new Document("_id", 1);

        return List.of(
                new Document("$match", match),
                new Document("$group", group),
                new Document("$sort", sort));
    }

    /**
     * Runs the down-sampling history query for a validated request and assembles
     * the {@link SensorHistory} response: one point per {@code $dateTrunc}
     * bucket, ascending by bucket start (empty when the range holds no data).
     * {@code deviceId}/{@code channel}/{@code unit}/{@code bucket} are echoed
     * from the request.
     */
    public SensorHistory history(SensorHistoryRequest request) {
        List<Document> pipeline = buildHistoryPipeline(
                request.deviceId(), request.channel(), request.from(), request.to(), request.bucket());

        List<SensorHistory.Point> points = new ArrayList<>();
        collection.aggregate(pipeline).forEach((Document doc) -> points.add(toPoint(doc)));

        return new SensorHistory(
                request.deviceId(), request.channel(), request.unit(), request.bucket().label(), points);
    }

    /** Maps one {@code $group} result document to a response point. */
    static SensorHistory.Point toPoint(Document groupDoc) {
        return new SensorHistory.Point(
                toIsoTimestamp(groupDoc.get("_id")),
                toDouble(groupDoc.get("avg")),
                toDouble(groupDoc.get("min")),
                toDouble(groupDoc.get("max")));
    }

    private static Double toDouble(Object value) {
        return (value instanceof Number number) ? number.doubleValue() : null;
    }

    private static String toIsoTimestamp(Object bucketStart) {
        if (bucketStart instanceof Date date) {
            return date.toInstant().toString();
        }
        if (bucketStart instanceof Instant instant) {
            return instant.toString();
        }
        return bucketStart == null ? null : bucketStart.toString();
    }

    /**
     * Returns the MongoDB collection for Change Stream listening.
     *
     * @return the {@code sensor_readings} collection
     */
    public MongoCollection<Document> getCollection() {
        return collection;
    }
}
