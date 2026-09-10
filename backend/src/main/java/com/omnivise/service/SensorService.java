package com.omnivise.service;

import java.util.ArrayList;
import java.util.List;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.omnivise.mapper.SensorReadingMapper;
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
     * Returns the MongoDB collection for Change Stream listening.
     *
     * @return the {@code sensor_readings} collection
     */
    public MongoCollection<Document> getCollection() {
        return collection;
    }
}
