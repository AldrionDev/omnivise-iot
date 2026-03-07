package com.omnivise;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.SensorReading;
import com.omnivise.service.SensorChangeStreamListener;
import com.omnivise.service.SensorService;

import io.github.cdimascio.dotenv.Dotenv;
import io.javalin.Javalin;

public class Main {
    private static Dotenv dotenv;

    public static void main(String[] args) {
        // Load the .env file from the project root
        dotenv = loadDotenvFromProjectRoot();

        // MongoDB connection string (no authentication for dev)
        String mongoHost = dotenv.get("MONGO_HOST", "localhost");
        String mongoPort = dotenv.get("MONGO_PORT", "27017");
        String mongoUri = String.format("mongodb://%s:%s", mongoHost, mongoPort);

        String mongoDatabase = dotenv.get("MONGO_DATABASE", "omnivise_iot");

        // Port setting from .env or default to 8080
        int port = Integer.parseInt(dotenv.get("BACKEND_PORT", "8080"));

        System.out.println("🚀 Starting OmniVise-IoT Backend...");
        System.out.println("📂 .env file loaded: " + getDotenvPath());
        System.out.println("🔌 MongoDB URI: " + mongoUri);
        System.out.println("🌐 Port: " + port);

        // Initialize MongoDB service
        SensorService sensorService = new SensorService(mongoUri, mongoDatabase);

        // Initialize WebSocket handler
        WebSocketHandler wsHandler = new WebSocketHandler();
        System.out.println("🔌 WebSocket handler initialized");

        // Initialize and start MongoDB Change Stream Listener
        SensorChangeStreamListener changeStreamListener = new SensorChangeStreamListener(
                sensorService.getCollection(),
                wsHandler);
        changeStreamListener.start();

        // Test MongoDB connection by fetching 5 latest readings
        List<SensorReading> testLatestReadings = sensorService.getLatestReadings(5);
        System.out.println("📊 Latest 5 sensor readings: " + testLatestReadings.size() + " found");
        if (!testLatestReadings.isEmpty()) {
            System.out.println(
                    " - Example: " + testLatestReadings.get(0).sensorId() + " | " + testLatestReadings.get(0).type()
                            + " | " + testLatestReadings.get(0).value() + " " + testLatestReadings.get(0).unit() + " | "
                            + testLatestReadings.get(0).location() + " | " + testLatestReadings.get(0).timestamp());
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

        // Get latest sensor readings
        // GET /api/sensors/latest?limit=50
        app.get("/api/sensors/latest", ctx -> {
            int limit = ctx.queryParamAsClass("limit", Integer.class).getOrDefault(50);
            List<SensorReading> readings = sensorService.getLatestReadings(limit);
            ctx.json(readings);
        });

        // Get readings by type
        // GET /api/sensors/type/{type}?limit=50
        app.get("/api/sensors/type/{type}", ctx -> {
            String type = ctx.pathParam("type");
            int limit = ctx.queryParamAsClass("limit", Integer.class).getOrDefault(50);
            List<SensorReading> readings = sensorService.getReadingsByType(type, limit);
            ctx.json(readings);
        });

        // Get readings by location
        // GET /api/sensors/location/{location}?limit=50
        app.get("/api/sensors/location/{location}", ctx -> {
            String location = ctx.pathParam("location");
            int limit = ctx.queryParamAsClass("limit", Integer.class).getOrDefault(50);
            List<SensorReading> readings = sensorService.getReadingsByLocation(location, limit);
            ctx.json(readings);
        });

        System.out.println("✅ Server running at http://localhost:" + port);
        System.out.println("\n📡 WebSocket endpoint:");
        System.out.println("   WS   /ws/sensors");
        System.out.println("\n📋 REST API endpoints:");
        System.out.println("   GET  /");
        System.out.println("   GET  /health");
        System.out.println("   GET  /api/sensors/latest?limit=50");
        System.out.println("   GET  /api/sensors/type/{type}?limit=50");
        System.out.println("   GET  /api/sensors/location/{location}?limit=50");
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
