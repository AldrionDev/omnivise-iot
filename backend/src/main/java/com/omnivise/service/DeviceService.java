package com.omnivise.service;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import org.bson.Document;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.omnivise.model.Device;

/**
 * In-memory view of the seeded {@code devices} registry (issue #70).
 *
 * <p>The registry is small and read-only, so every document is loaded once at
 * construction time and all queries are answered from memory. Insertion order
 * (the seed order) is preserved.
 */
public class DeviceService {

    private final Map<String, Device> devicesById;

    /**
     * Connects to MongoDB, reads the whole {@code devices} collection and holds
     * it in memory.
     *
     * @param mongoUri MongoDB connection URI
     * @param database database name (e.g. {@code omnivise_iot})
     */
    public DeviceService(String mongoUri, String database) {
        this(readAll(mongoUri, database));
    }

    /**
     * Test seam: build the registry directly from device documents, without a
     * live MongoDB.
     */
    DeviceService(List<Document> deviceDocuments) {
        Map<String, Device> byId = new LinkedHashMap<>();
        for (Document doc : deviceDocuments) {
            Device device = documentToDevice(doc);
            byId.put(device.deviceId(), device);
        }
        this.devicesById = Collections.unmodifiableMap(byId);
        System.out.println("✅ Device registry loaded: " + this.devicesById.size() + " device(s)");
    }

    /** All devices, in seed order. */
    public List<Device> getAllDevices() {
        return List.copyOf(devicesById.values());
    }

    /** One device by id, or {@link Optional#empty()} if unknown. */
    public Optional<Device> getDevice(String deviceId) {
        return Optional.ofNullable(devicesById.get(deviceId));
    }

    /**
     * The registered unit for one {@code deviceId} + {@code channel} pair, used
     * by the history endpoint (issue #72) to fill the response {@code unit}.
     *
     * @return the channel's unit, or {@link Optional#empty()} if the device is
     *         unknown or does not declare that channel
     */
    public Optional<String> findChannelUnit(String deviceId, String channel) {
        Device device = devicesById.get(deviceId);
        if (device == null) {
            return Optional.empty();
        }
        return device.channels().stream()
                .filter(c -> c.channel().equals(channel))
                .map(Device.Channel::unit)
                .findFirst();
    }

    /**
     * Maps a {@code devices} document to a {@link Device}. Package-private so the
     * mapping contract (including the nested {@code channels} array) can be
     * unit-tested directly.
     */
    static Device documentToDevice(Document doc) {
        List<Device.Channel> channels = new ArrayList<>();
        List<Document> channelDocs = doc.getList("channels", Document.class);
        if (channelDocs != null) {
            for (Document channelDoc : channelDocs) {
                channels.add(new Device.Channel(
                        channelDoc.getString("channel"),
                        channelDoc.getString("unit")));
            }
        }
        return new Device(
                doc.getString("deviceId"),
                doc.getString("name"),
                doc.getString("kind"),
                doc.getString("location"),
                List.copyOf(channels));
    }

    private static List<Document> readAll(String mongoUri, String database) {
        MongoClient mongoClient = MongoClients.create(mongoUri);
        MongoDatabase db = mongoClient.getDatabase(database);
        MongoCollection<Document> collection = db.getCollection("devices");
        List<Document> docs = new ArrayList<>();
        collection.find().forEach(docs::add);
        return docs;
    }
}
