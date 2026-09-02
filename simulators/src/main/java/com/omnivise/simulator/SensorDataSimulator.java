package com.omnivise.simulator;

import java.time.Instant;
import java.util.Random;
import java.util.concurrent.TimeUnit;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;

/**
 * Sensor Data Simulator - Continuously generates random sensor data
 * and writes them to MongoDB.
 * 
 * This program simulates the behavior of IoT sensors as if real devices
 * were sending data to the system.
 */
public class SensorDataSimulator {

    // Default values for environment variables
    private static final String MONGO_URI = System.getenv().getOrDefault(
            "MONGO_URI", "mongodb://admin:admin123@localhost:27017");
    private static final String DATABASE_NAME = System.getenv().getOrDefault(
            "MONGO_DATABASE", "omnivise_iot");
    private static final String COLLECTION_NAME = System.getenv().getOrDefault(
            "MONGO_COLLECTION", "sensor_readings");
    private static final int INTERVAL_SECONDS = Integer.parseInt(
            System.getenv().getOrDefault("INTERVAL_SECONDS", "5"));

    private static final Random random = new Random();

    public static void main(String[] args) {
        System.out.println("🚀 Starting Sensor Data Simulator...");
        System.out.println("📡 MongoDB connection configured");
        System.out.println("💾 Database: " + DATABASE_NAME);
        System.out.println("📋 Collection: " + COLLECTION_NAME);
        System.out.println("⏱️  Interval: " + INTERVAL_SECONDS + " seconds");
        System.out.println("-".repeat(60));

        // Creating MongoDB connection
        try (MongoClient mongoClient = MongoClients.create(MONGO_URI)) {
            MongoDatabase database = mongoClient.getDatabase(DATABASE_NAME);
            MongoCollection<Document> collection = database.getCollection(COLLECTION_NAME);

            System.out.println("✅ MongoDB connection successfully established!");
            System.out.println("🤖 Sensor data generation started...\n");

            // Infinite loop - continuously generating data
            long generatedCount = 0;
            while (true) {
                try {
                    Document sensorData = generateRandomSensorData();
                    collection.insertOne(sensorData);
                    generatedCount++;

                    // Formatted output by type
                    Object value = sensorData.get("value");
                    String formattedValue;
                    if (value instanceof Double) {
                        formattedValue = String.format("%.2f", value);
                    } else {
                        formattedValue = value.toString();
                    }

                    System.out.printf("[%d] ✅ Inserted: %s | %s = %s %s%n",
                            generatedCount,
                            sensorData.getString("sensor_id"),
                            sensorData.getString("type"),
                            formattedValue,
                            sensorData.getString("unit"));

                    // Waiting until next generation
                    TimeUnit.SECONDS.sleep(INTERVAL_SECONDS);

                } catch (InterruptedException e) {
                    System.err.println("⚠️ Simulation was interrupted.");
                    Thread.currentThread().interrupt();
                    break;
                } catch (Exception e) {
                    System.err.println("❌ Error during data generation: " + e.getMessage());
                    e.printStackTrace();
                }
            }

        } catch (Exception e) {
            System.err.println("❌ MongoDB connection error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }

    /**
     * Generates random sensor data.
     * 
     * @return MongoDB Document with the data
     */
    private static Document generateRandomSensorData() {
        // List of sensor types
        String[] types = { "temperature", "humidity", "motion", "light", "pressure" };
        String[] locations = { "Office Room 1", "Office Room 2", "Server Room",
                "Entrance", "Lobby", "Meeting Room" };

        String type = types[random.nextInt(types.length)];
        String location = locations[random.nextInt(locations.length)];
        String sensorId = String.format("sensor_%03d", random.nextInt(100) + 1);

        // Value and unit based on type
        Object value;
        String unit;

        switch (type) {
            case "temperature":
                value = round(15.0 + random.nextDouble() * 15.0, 1); // 15-30°C
                unit = "°C";
                break;
            case "humidity":
                value = round(40.0 + random.nextDouble() * 40.0, 1); // 40-80%
                unit = "%";
                break;
            case "motion":
                boolean motionDetected = random.nextBoolean();
                value = motionDetected ? 1 : 0; // 1 for motion detected, 0 for no motion
                unit = motionDetected ? "detected" : "no motion";
                break;
            case "light":
                value = random.nextInt(1000); // 0-1000 lux
                unit = "lux";
                break;
            case "pressure":
                value = round(980.0 + random.nextDouble() * 60.0, 1); // 980-1040 hPa
                unit = "hPa";
                break;
            default:
                value = 0;
                unit = "unknown";
        }

        // Creating MongoDB Document
        return new Document()
                .append("sensor_id", sensorId)
                .append("type", type)
                .append("value", value)
                .append("unit", unit)
                .append("location", location)
                .append("timestamp", Instant.now().toString());
    }

    /**
     * Rounds to specified decimal places.
     */
    private static double round(double value, int decimals) {
        double multiplier = Math.pow(10, decimals);
        return Math.round(value * multiplier) / multiplier;
    }

}
