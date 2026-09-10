package com.omnivise;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.Map;

import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.Device;
import com.omnivise.model.SensorReading;
import com.omnivise.service.DeviceService;
import com.omnivise.service.SensorChangeStreamListener;
import com.omnivise.service.SensorService;

import io.github.cdimascio.dotenv.Dotenv;
import io.javalin.Javalin;

public class Main {
    private static Dotenv dotenv;

    public static void main(String[] args) {
        // Load the .env file from the project root
        dotenv = loadDotenvFromProjectRoot();

        String explicitMongoUri = getEnvVar("MONGO_URI", null);
        String mongoHost = getEnvVar("MONGO_HOST", "localhost");
        String mongoPort = getEnvVar("MONGO_PORT", "27017");
        String mongoUser = getEnvVar("MONGO_USER", null);
        String mongoPassword = getEnvVar("MONGO_PASSWORD", null);

        String mongoUri = resolveMongoUri(
                explicitMongoUri,
                mongoHost,
                mongoPort,
                mongoUser,
                mongoPassword);

        String mongoDatabase = getEnvVar("MONGO_DATABASE", "omnivise_iot");

        // Port setting from .env or default to 8080
        int port = Integer.parseInt(getEnvVar("BACKEND_PORT", "8080"));

        System.out.println("🚀 Starting OmniVise-IoT Backend...");
        System.out.println("📂 .env file loaded: " + getDotenvPath());
        System.out.println("🔌 MongoDB connection configured for database: " + mongoDatabase);
        System.out.println("🌐 Port: " + port);

        // Initialize MongoDB services
        SensorService sensorService = new SensorService(mongoUri, mongoDatabase);
        DeviceService deviceService = new DeviceService(mongoUri, mongoDatabase);

        // Initialize WebSocket handler
        WebSocketHandler wsHandler = new WebSocketHandler();
        System.out.println("🔌 WebSocket handler initialized");

        // Initialize and start MongoDB Change Stream Listener
        SensorChangeStreamListener changeStreamListener = new SensorChangeStreamListener(
                sensorService.getCollection(),
                wsHandler);
        changeStreamListener.start();

        // Stop the Change Stream listener cleanly on application shutdown (SIGTERM / Ctrl-C).
        Runtime.getRuntime().addShutdownHook(
                new Thread(changeStreamListener::stop, "shutdown-changestream"));

        // Test MongoDB connection by fetching 5 latest readings
        List<SensorReading> testLatestReadings = sensorService.getLatestReadings(null, null, 5);
        System.out.println("📊 Latest 5 sensor readings: " + testLatestReadings.size() + " found");
        if (!testLatestReadings.isEmpty()) {
            SensorReading example = testLatestReadings.get(0);
            System.out.println(
                    " - Example: " + example.deviceId() + " | " + example.channel()
                            + " | " + example.value() + " " + example.unit() + " | " + example.timestamp());
        }

        // Javalin app create and start
        Javalin app = Javalin.create(config -> {
            config.showJavalinBanner = false;
            config.http.defaultContentType = "application/json";

            // Enable CORS for frontend (React app on different port)
            config.bundledPlugins.enableCors(cors -> {
                cors.addRule(it -> {
                    it.anyHost();
                });
            });

        }).start(port);

        /**
         * Define WebSocket endpoint
         */
        app.ws("/ws/sensors", wsHandler.getWebSocketConfig());

        /**
         * Define REST API endpoints
         */

        // Base endpoint
        app.get("/", ctx -> ctx.json(new Response("OmniVise-IoT API", "v1.0")));

        // Health check endpoint
        app.get("/health", ctx -> ctx.json(new Response("status", "healthy")));

        // Device registry (seeded, read-only)
        // GET /api/devices
        app.get("/api/devices", ctx -> ctx.json(deviceService.getAllDevices()));

        // GET /api/devices/{deviceId}
        app.get("/api/devices/{deviceId}", ctx -> {
            String deviceId = ctx.pathParam("deviceId");
            Device device = deviceService.getDevice(deviceId).orElse(null);
            if (device == null) {
                ctx.status(404).json(Map.of("error", "device not found", "deviceId", deviceId));
                return;
            }
            ctx.json(device);
        });

        // Latest sensor readings, newest first, optional deviceId / channel filters
        // GET /api/sensors/latest?deviceId=&channel=&limit=50
        app.get("/api/sensors/latest", ctx -> {
            String deviceId = ctx.queryParam("deviceId");
            String channel = ctx.queryParam("channel");
            int limit = clampLimit(ctx.queryParamAsClass("limit", Integer.class).getOrDefault(50));
            List<SensorReading> readings = sensorService.getLatestReadings(deviceId, channel, limit);
            ctx.json(readings);
        });

        System.out.println("✅ Server running at http://localhost:" + port);
        System.out.println("\n📡 WebSocket endpoint:");
        System.out.println("   WS   /ws/sensors");
        System.out.println("\n📋 REST API endpoints:");
        System.out.println("   GET  /");
        System.out.println("   GET  /health");
        System.out.println("   GET  /api/devices");
        System.out.println("   GET  /api/devices/{deviceId}");
        System.out.println("   GET  /api/sensors/latest?deviceId=&channel=&limit=50");
    }

    /** Keeps the {@code limit} query parameter within a sane, non-negative range. */
    static int clampLimit(int requested) {
        if (requested < 1) {
            return 1;
        }
        return Math.min(requested, 500);
    }

    /**
     * Loads the .env file from the project root.
     * The backend code is in the /backend folder, but the .env file is in the
     * project root.
     */
    private static Dotenv loadDotenvFromProjectRoot() {
        Path currentDir = Paths.get("").toAbsolutePath();

        Path parentDotenv = currentDir.getParent().resolve(".env");
        if (parentDotenv.toFile().exists()) {
            System.out.println("📄 .env file found: " + parentDotenv);
            return Dotenv.configure()
                    .directory(parentDotenv.getParent().toString())
                    .ignoreIfMissing()
                    .load();
        }

        Path currentDotenv = currentDir.resolve(".env");
        if (currentDotenv.toFile().exists()) {
            System.out.println("📄 .env file found: " + currentDotenv);
            return Dotenv.configure()
                    .directory(currentDir.toString())
                    .ignoreIfMissing()
                    .load();
        }

        System.out.println("⚠️  No .env file! Using environment variables or default values.");
        return Dotenv.configure()
                .ignoreIfMissing()
                .load();
    }

    /**
     * Returns the path of the loaded .env file for logging purposes.
     */
    private static String getDotenvPath() {
        Path currentDir = Paths.get("").toAbsolutePath();
        Path parentDotenv = currentDir.getParent().resolve(".env");

        if (parentDotenv.toFile().exists()) {
            return parentDotenv.toString();
        }

        Path currentDotenv = currentDir.resolve(".env");
        if (currentDotenv.toFile().exists()) {
            return currentDotenv.toString();
        }

        return "nincs .env fájl";
    }

    /**
     * Get environment variable with fallback to System.getenv()
     * This works both in development (with .env file) and in Docker (with env vars)
     */
    private static String getEnvVar(String key, String defaultValue) {
        // First try dotenv (for local development)
        String value = dotenv.get(key);

        // If not found, try System.getenv() (for Docker containers)
        if (value == null || value.isEmpty()) {
            value = System.getenv(key);
        }

        // If still not found, use default value
        return (value != null && !value.isEmpty()) ? value : defaultValue;
    }

    /**
     * Resolves the MongoDB connection URI.
     *
     * An explicit non-empty MONGO_URI is authoritative. When it is absent or
     * empty, preserve the legacy host/port/user/password URI construction.
     */
    static String resolveMongoUri(
            String explicitMongoUri,
            String mongoHost,
            String mongoPort,
            String mongoUser,
            String mongoPassword) {
        if (explicitMongoUri != null && !explicitMongoUri.isEmpty()) {
            return explicitMongoUri;
        }

        if (mongoUser != null && mongoPassword != null
                && !mongoUser.isEmpty() && !mongoPassword.isEmpty()) {
            return String.format(
                    "mongodb://%s:%s@%s:%s/?directConnection=true",
                    mongoUser,
                    mongoPassword,
                    mongoHost,
                    mongoPort);
        }

        return String.format("mongodb://%s:%s", mongoHost, mongoPort);
    }

    /**
     * Helper function for querying environment variables
     */
    public static String getEnv(String key) {
        String value = dotenv.get(key);
        if (value == null) {
            throw new IllegalStateException("Missing required environment variable:" + key);
        }
        return value;
    }

    public static String getEnv(String key, String defaultValue) {
        return dotenv.get(key, defaultValue);
    }

    record Response(String message, String version) {
    }
}
