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

    public SensorService(String mongoUri, String database) {
        MongoClient mongoClient = MongoClients.create(mongoUri);
        MongoDatabase db = mongoClient.getDatabase(database);
        this.collection = db.getCollection("sensor_readings");
        System.out.println("✅ MongoDB connected: " + database + ".sensor_readings");
    }

    public List<SensorReading> getLatestReadings(int limit) {
        List<SensorReading> readings = new ArrayList<>();

        collection.find()
                .sort(new Document("timestamp", -1))
                .limit(limit)
                .forEach(doc -> readings.add(documentToReading(doc)));

        return readings;
    }

    private SensorReading documentToReading(Document doc) {
        return new SensorReading(
                doc.getString("sensor_id"),
                doc.getString("type"),
                doc.get("value"),
                doc.getString("unit"),
                doc.getString("location"),
                doc.getDate("timestamp").toString());
    }

    public List<SensorReading> getReadingsByType(String type, int limit) {
        List<SensorReading> readings = new ArrayList<>();
        collection.find(new Document("type", type))
                .sort(new Document("timestamp", -1))
                .limit(limit)
                .forEach(doc -> readings.add(documentToReading(doc)));
        return readings;
    }

    public List<SensorReading> getReadingsByLocation(String location, int limit) {
        List<SensorReading> readings = new ArrayList<>();
        collection.find(new Document("location", location))
                .sort(new Document("timestamp", -1))
                .limit(limit)
                .forEach(doc -> readings.add(documentToReading(doc)));
        return readings;
    }
}
