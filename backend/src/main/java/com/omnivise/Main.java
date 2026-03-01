package com.omnivise;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;

import com.omnivise.model.SensorReading;
import com.omnivise.service.SensorService;

import io.github.cdimascio.dotenv.Dotenv;
import io.javalin.Javalin;

public class Main {
    private static Dotenv dotenv;

    public static void main(String[] args) {
        // Load the .env file from the project root
        dotenv = loadDotenvFromProjectRoot();

        // MongoDB connection string composed from .env variables or defaults
        String mongoUser = dotenv.get("MONGO_USER", "admin");
        String mongoPassword = dotenv.get("MONGO_PASSWORD", "password");
        String mongoHost = dotenv.get("MONGO_HOST", "localhost");
        String mongoPort = dotenv.get("MONGO_PORT", "27017");
        String mongoUri = String.format("mongodb://%s:%s@%s:%s",
                mongoUser, mongoPassword, mongoHost, mongoPort);

        String mongoDatabase = dotenv.get("MONGO_DATABASE", "omnivise_iot");

        // Port setting from .env or default to 8080
        int port = Integer.parseInt(dotenv.get("BACKEND_PORT", "8080"));

        System.out.println("🚀 Starting OmniVise-IoT Backend...");
        System.out.println("📂 .env file loaded: " + getDotenvPath());
        String maskedUri = mongoUri.replaceAll("://.*@", "://***:***@");
        System.out.println("🔌 MongoDB URI: " + maskedUri);
        System.out.println("🌐 Port: " + port);

        // Initialize MongoDB service
        SensorService sensorService = new SensorService(mongoUri, mongoDatabase);

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
        }).start(port);

        // Base endpoint
        app.get("/", ctx -> ctx.json(new Response("OmniVise-IoT API", "v1.0")));

        // Health check endpoint
        app.get("/health", ctx -> ctx.json(new Response("status", "healthy")));

        System.out.println("✅ Server running at http://localhost:" + port);
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
