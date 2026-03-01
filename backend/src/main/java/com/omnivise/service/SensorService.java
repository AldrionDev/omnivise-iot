package com.omnivise.service;

import java.util.ArrayList;
import java.util.List;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.omnivise.model.SensorReading;

/**
 * Service layer for sensor data operations.
 * Handles MongoDB connection and data retrieval for sensor readings
 */

public class SensorService {

    private final MongoCollection<Document> collection;

    /**
     * Initializes the SensorService and establishes connection to MongoDB.
     * Creates a MongoDB client, connects to the specified database,
     * and retrieves the 'sensor_readings' collection.
     * 
     * @param mongoUri The MongoDB connection URI (e.g.,
     *                 "mongodb://user:pass@host:27017")
     * @param database Database name to connect to (e.g., "omnivise_iot")
     */
    public SensorService(String mongoUri, String database) {
        MongoClient mongoClient = MongoClients.create(mongoUri);
        MongoDatabase db = mongoClient.getDatabase(database);
        this.collection = db.getCollection("sensor_readings");
        System.out.println("✅ MongoDB connected: " + database + ".sensor_readings");
    }

    /**
     * Retrieves the latest sensor readings from the database.
     * Results are sorted by timestamp in descending order (newest first).
     * 
     * @param limit The maximum number of readings to return
     * @return List of SensorReading objects, sorted by timestamp (newest first)
     */
    public List<SensorReading> getLatestReadings(int limit) {
        List<SensorReading> readings = new ArrayList<>();

        collection.find()
                .sort(new Document("timestamp", -1))
                .limit(limit)
                .forEach(doc -> readings.add(documentToReading(doc)));

        return readings;
    }

    /**
     * Helper method to convert a MongoDB Document into a SensorReading record.
     * 
     * @param doc The MongoDB document from the sensor_readings collection
     * @return A SensorReading object with mapped fields from the document
     */
    private SensorReading documentToReading(Document doc) {
        Object timestampObj = doc.get("timestamp");
        String timestamp;
        if (timestampObj instanceof java.util.Date) {
            timestamp = timestampObj.toString();
        } else if (timestampObj instanceof String) {
            timestamp = (String) timestampObj;
        } else {
            timestamp = String.valueOf(timestampObj);
        }
        return new SensorReading(
                doc.getString("sensor_id"),
                doc.getString("type"),
                doc.get("value"),
                doc.getString("unit"),
                doc.getString("location"),
                timestamp);
    }

    /**
     * Retrieves sensor readings filtered by sensor type.
     * Results are sorted by timestamp in descending order (newest first).
     * 
     * @param type  The sensor type to filter by (e.g., "temperature")
     * @param limit The maximum number of readings to return
     * @return List of SensorReading objects, sorted by timestamp (newest first)
     * 
     */
    public List<SensorReading> getReadingsByType(String type, int limit) {
        List<SensorReading> readings = new ArrayList<>();
        collection.find(new Document("type", type))
                .sort(new Document("timestamp", -1))
                .limit(limit)
                .forEach(doc -> readings.add(documentToReading(doc)));
        return readings;
    }

    /**
     * Retrieves sensor readings filtered by location.
     * Results are sorted by timestamp in descending order (newest first).
     * 
     * @param location The location to filter by (e.g., "living_room")
     * @param limit    The maximum number of readings to return
     * @return List of SensorReading objects from the specified location.
     */
    public List<SensorReading> getReadingsByLocation(String location, int limit) {
        List<SensorReading> readings = new ArrayList<>();
        collection.find(new Document("location", location))
                .sort(new Document("timestamp", -1))
                .limit(limit)
                .forEach(doc -> readings.add(documentToReading(doc)));
        return readings;
    }
}
