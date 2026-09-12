package com.omnivise;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.List;
import java.util.Map;

import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.AlertRule;
import com.omnivise.model.Device;
import com.omnivise.model.SensorReading;
import com.omnivise.service.AlertEvaluator;
import com.omnivise.service.AlertQuery;
import com.omnivise.service.AlertRuleService;
import com.omnivise.service.AlertRulesQuery;
import com.omnivise.service.AlertService;
import com.omnivise.service.DeviceService;
import com.omnivise.service.SensorChangeStreamListener;
import com.omnivise.service.SensorHistoryRequest;
import com.omnivise.service.SensorService;
import com.omnivise.webhook.AlertWebhook;

import io.github.cdimascio.dotenv.Dotenv;
import io.javalin.Javalin;

public class Main {

    /**
     * Approved maximum number of aligned {@code $dateTrunc} buckets a single
     * history query may span; a larger range/bucket combination is rejected with
     * {@code 400}. Maintainer decision for issue #72.
     */
    static final int HISTORY_MAX_BUCKET_COUNT = 1000;

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

        String mongoDatabase = resolveMongoDatabase(getEnvVarPreservingBlank("MONGO_DATABASE"));

        // Port setting from .env or default to 8080
        int port = Integer.parseInt(getEnvVar("BACKEND_PORT", "8080"));

        System.out.println("🚀 Starting OmniVise-IoT Backend...");
        System.out.println("📂 .env file loaded: " + getDotenvPath());
        System.out.println("🔌 MongoDB connection configured for database: " + mongoDatabase);
        System.out.println("🌐 Port: " + port);

        // Initialize MongoDB services
        SensorService sensorService = new SensorService(mongoUri, mongoDatabase);
        DeviceService deviceService = new DeviceService(mongoUri, mongoDatabase);
        AlertService alertService = new AlertService(mongoUri, mongoDatabase);

        // Threshold alerting (issue #73). Both of these fail startup on bad
        // configuration rather than running a silently incomplete alert policy:
        // an invalid enabled seeded rule, or a non-blank but malformed
        // ALERT_WEBHOOK_URL. An unset/blank ALERT_WEBHOOK_URL disables the webhook.
        AlertRuleService alertRuleService = new AlertRuleService(mongoUri, mongoDatabase);
        AlertWebhook alertWebhook = AlertWebhook.fromConfig(getEnvVar("ALERT_WEBHOOK_URL", null));
        System.out.println("🔔 Alert rules: " + alertRuleService.getRules().size()
                + " enabled; webhook " + alertWebhook.getClass().getSimpleName());

        // Initialize WebSocket handler
        WebSocketHandler wsHandler = new WebSocketHandler();
        System.out.println("🔌 WebSocket handler initialized");

        AlertEvaluator alertEvaluator = new AlertEvaluator(
                alertService,
                alertRuleService,
                deviceService,
                wsHandler,
                alertWebhook);

        // Initialize and start MongoDB Change Stream Listener
        SensorChangeStreamListener changeStreamListener = new SensorChangeStreamListener(
                sensorService.getCollection(),
                wsHandler,
                alertEvaluator);
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
                    it.exposeHeader(AlertService.WATERMARK_HEADER);
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

        // Down-sampled time-series for one device/channel over a time range.
        // GET /api/sensors/history?deviceId=&channel=&from=&to=&bucket=1m|5m|1h
        app.get("/api/sensors/history", ctx -> {
            SensorHistoryRequest.Result parsed = SensorHistoryRequest.parse(
                    ctx.queryParam("deviceId"),
                    ctx.queryParam("channel"),
                    ctx.queryParam("from"),
                    ctx.queryParam("to"),
                    ctx.queryParam("bucket"),
                    deviceService,
                    HISTORY_MAX_BUCKET_COUNT);

            // parsed is a sealed Result: reject Invalid with a structured 400,
            // otherwise run the history query for the normalised Valid request.
            if (parsed instanceof SensorHistoryRequest.Invalid invalid) {
                ctx.status(400).json(invalid);
                return;
            }
            SensorHistoryRequest request = ((SensorHistoryRequest.Valid) parsed).request();
            ctx.json(sensorService.history(request));
        });

        // Alert events, newest first, optional state / severity / deviceId / limit.
        // GET /api/alerts?state=firing|resolved&severity=warning|critical&deviceId=&limit=100
        app.get("/api/alerts", ctx -> {
            AlertQuery.Result parsed = AlertQuery.parse(
                    ctx.queryParam("state"),
                    ctx.queryParam("severity"),
                    ctx.queryParam("deviceId"),
                    ctx.queryParam("limit"));
            if (parsed instanceof AlertQuery.Invalid invalid) {
                ctx.status(400).json(invalid);
                return;
            }
            AlertService.Snapshot snapshot = alertService.findSnapshot(((AlertQuery.Valid) parsed).query());
            ctx.header(AlertService.WATERMARK_HEADER, Long.toString(snapshot.watermark()));
            ctx.json(snapshot.events());
        });

        // Convenience for state=firing; the caller cannot override state.
        // GET /api/alerts/active?severity=&deviceId=&limit=100
        app.get("/api/alerts/active", ctx -> {
            AlertQuery.Result parsed = AlertQuery.forActive(
                    ctx.queryParam("severity"),
                    ctx.queryParam("deviceId"),
                    ctx.queryParam("limit"));
            if (parsed instanceof AlertQuery.Invalid invalid) {
                ctx.status(400).json(invalid);
                return;
            }
            AlertService.Snapshot snapshot = alertService.findSnapshot(((AlertQuery.Valid) parsed).query());
            ctx.header(AlertService.WATERMARK_HEADER, Long.toString(snapshot.watermark()));
            ctx.json(snapshot.events());
        });

        // Seeded, read-only threshold-rule registry (issue #73), exposed read-only
        // (issue #89). Without deviceId: all enabled rules. With deviceId: only the
        // rules applicable to that device (channel-independent device matching).
        // GET /api/alerts/rules?deviceId=
        app.get("/api/alerts/rules", ctx -> {
            AlertRulesQuery.Result parsed = AlertRulesQuery.parse(
                    ctx.queryParam("deviceId"), deviceService);
            if (parsed instanceof AlertRulesQuery.Invalid invalid) {
                ctx.status(400).json(invalid);
                return;
            }
            AlertRulesQuery.Valid valid = (AlertRulesQuery.Valid) parsed;
            List<AlertRule> rules = valid.deviceId() == null
                    ? alertRuleService.getRules()
                    : alertRuleService.getRulesForDevice(valid.deviceId(), valid.deviceKind());
            ctx.json(rules);
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
        System.out.println("   GET  /api/sensors/history?deviceId=&channel=&from=&to=&bucket=1m|5m|1h");
        System.out.println("   GET  /api/alerts?state=firing|resolved&severity=&deviceId=&limit=100");
        System.out.println("   GET  /api/alerts/active?severity=&deviceId=&limit=100");
        System.out.println("   GET  /api/alerts/rules?deviceId=");
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

    private static String getEnvVarPreservingBlank(String key) {
        String value = dotenv.get(key);
        return value != null ? value : System.getenv(key);
    }

    static String resolveMongoDatabase(String value) {
        if (value == null) {
            return "omnivise_iot";
        }
        if (value.isBlank()) {
            throw new IllegalArgumentException("MONGO_DATABASE must select an application database");
        }
        return value;
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
