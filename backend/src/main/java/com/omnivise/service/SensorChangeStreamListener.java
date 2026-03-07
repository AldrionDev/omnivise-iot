package com.omnivise.service;

import org.bson.Document;

import com.mongodb.client.MongoCollection;
import com.mongodb.client.model.changestream.ChangeStreamDocument;
import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.SensorReading;

/**
 * Listens to MongoDB Change Stream events and broadcasts new sensor readings
 * to all connected WebSocket clients in real-time.
 * 
 * This enables automatic push notifications whenever the simulator (or any
 * other source)
 * inserts new data into the MongoDB sensor_readings collection.
 */
public class SensorChangeStreamListener {

    private final MongoCollection<Document> collection;
    private final WebSocketHandler wsHandler;
    private Thread listenerThread;
    private volatile boolean running = false;

    /**
     * Creates a new Change Stream Listener.
     * 
     * @param collection MongoDB collection to watch for changes
     * @param wsHandler  WebSocket handler for broadcasting data
     */
    public SensorChangeStreamListener(MongoCollection<Document> collection, WebSocketHandler wsHandler) {
        this.collection = collection;
        this.wsHandler = wsHandler;
    }

    /**
     * Starts listening to MongoDB Change Stream in a separate thread.
     * Only watches for 'insert' operations.
     */
    public void start() {
        if (running) {
            System.out.println("⚠️ Change Stream listener is already running");
            return;
        }

        running = true;
        listenerThread = new Thread(() -> {
            System.out.println("👂 MongoDB Change Stream listener started");

            try {
                // Watch for insert operations only
                collection.watch()
                        .forEach((ChangeStreamDocument<Document> change) -> {
                            // Only process insert events
                            if (change.getOperationType().getValue().equals("insert")) {
                                Document doc = change.getFullDocument();
                                if (doc != null) {
                                    // Convert MongoDB document to SensorReading
                                    SensorReading reading = documentToReading(doc);

                                    // Broadcast to all WebSocket clients
                                    wsHandler.broadcast(reading);

                                    System.out.println("📤 Broadcasted: " + reading.sensorId()
                                            + " | " + reading.type() + " = " + reading.value() + " " + reading.unit());
                                }
                            }
                        });
            } catch (Exception e) {
                if (running) {
                    System.err.println("❌ Change Stream error: " + e.getMessage());
                    e.printStackTrace();
                }
            }
        }, "ChangeStreamListener");

        listenerThread.setDaemon(true); // Allow JVM to exit even if this thread is running
        listenerThread.start();
    }

    /**
     * Stops the Change Stream listener.
     */
    public void stop() {
        running = false;
        if (listenerThread != null) {
            listenerThread.interrupt();
            System.out.println("🛑 Change Stream listener stopped");
        }
    }

    /**
     * Converts MongoDB Document to SensorReading record.
     * Handles different timestamp formats (Date, String, or other).
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
}
