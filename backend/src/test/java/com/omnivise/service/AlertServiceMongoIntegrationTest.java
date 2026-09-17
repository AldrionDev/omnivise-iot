package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import org.bson.Document;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoDatabase;
import com.mongodb.client.model.Filters;
import com.mongodb.client.model.IndexOptions;
import com.mongodb.client.model.Indexes;
import com.omnivise.handler.WebSocketHandler;
import com.omnivise.model.AlertEvent;
import com.omnivise.model.AlertRule;
import com.omnivise.model.SensorReading;

/**
 * Replica-set integration coverage for the transaction guarantees introduced by issue #94
 * and the single-firing-lifecycle ownership enforced by the partial unique index.
 */
class AlertServiceMongoIntegrationTest {

    private static final String INTEGRATION_URI_ENV = "MONGO_INTEGRATION_URI";

    @Test
    void allocatesConcurrentSequencesAndRollsBackTheCounterOnCasFailure() throws Exception {
        String uri = System.getenv(INTEGRATION_URI_ENV);
        Assumptions.assumeTrue(uri != null && !uri.isBlank(),
                INTEGRATION_URI_ENV + " is required for MongoDB integration tests");
        String database = "omnivise_alert_test_" + UUID.randomUUID().toString().replace("-", "");

        try (MongoClient inspector = MongoClients.create(uri)) {
            var mongoDatabase = inspector.getDatabase(database);
            AlertService service = new AlertService(inspector,
                    mongoDatabase.getCollection("alert_events"),
                    mongoDatabase.getCollection("alert_sequences"));
            var executor = Executors.newFixedThreadPool(4);
            try {
                List<Callable<AlertEvent>> inserts = new ArrayList<>();
                for (int i = 0; i < 12; i++) {
                    int index = i;
                    inserts.add(() -> service.insertFiring(pending(index)).orElseThrow());
                }
                List<AlertEvent> firing = executor.invokeAll(inserts).stream()
                        .map(AlertServiceMongoIntegrationTest::await)
                        .toList();

                assertEquals(12, new HashSet<>(firing.stream().map(AlertEvent::sequence).toList()).size());
                assertEquals(List.of(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L, 12L),
                        firing.stream().map(AlertEvent::sequence).sorted().toList());

                AlertEvent persisted = firing.getFirst();
                AlertEvent stale = new AlertEvent(persisted.id(), persisted.sequence() + 100,
                        persisted.ruleId(), persisted.deviceId(), persisted.channel(), persisted.severity(),
                        persisted.state(), persisted.triggeredValue(), persisted.lastValue(),
                        persisted.startedAt(), persisted.resolvedAt());
                assertTrue(service.resolve(stale, 20.0, "2026-09-11T08:01:00Z").isEmpty());

                Document counterAfterCasMiss = inspector.getDatabase(database)
                        .getCollection("alert_sequences").find(new Document("_id", "global")).first();
                assertEquals(12L, counterAfterCasMiss.getLong("value"));

                AlertEvent resolved = service.resolve(persisted, 20.0, "2026-09-11T08:01:00Z").orElseThrow();
                assertEquals(13L, resolved.sequence());
                AlertQuery query = ((AlertQuery.Valid) AlertQuery.parse(null, null, null, "100")).query();
                AlertService.Snapshot snapshot = service.findSnapshot(query);
                assertEquals(13L, snapshot.watermark());
                assertTrue(snapshot.events().stream().allMatch(event -> event.sequence() <= snapshot.watermark()));
                assertEquals(AlertEvent.STATE_RESOLVED, snapshot.events().stream()
                        .filter(event -> event.id().equals(resolved.id())).findFirst().orElseThrow().state());
            } finally {
                executor.shutdownNow();
                inspector.getDatabase(database).drop();
            }
        }
    }

    @Test
    void concurrentInsertForSameLogicalAlertKeepsOnlyOneFiringLifecycle() throws Exception {
        String uri = System.getenv(INTEGRATION_URI_ENV);
        Assumptions.assumeTrue(uri != null && !uri.isBlank(),
                INTEGRATION_URI_ENV + " is required for MongoDB integration tests");
        String database = "omnivise_alert_test_" + UUID.randomUUID().toString().replace("-", "");

        try (MongoClient inspector = MongoClients.create(uri)) {
            var mongoDatabase = inspector.getDatabase(database);
            createFiringUniqueIndex(mongoDatabase);
            AlertService service = new AlertService(inspector,
                    mongoDatabase.getCollection("alert_events"),
                    mongoDatabase.getCollection("alert_sequences"));
            var executor = Executors.newFixedThreadPool(8);
            try {
                AlertEvent pending = new AlertEvent(null, 0,
                        "ups-input-voltage-low", "ups-1", "input_voltage",
                        "critical", AlertEvent.STATE_FIRING, 2.0, 2.0,
                        "2026-09-11T08:00:00Z", null);

                List<Callable<Optional<AlertEvent>>> inserts = new ArrayList<>();
                for (int i = 0; i < 8; i++) {
                    inserts.add(() -> service.insertFiring(pending));
                }
                List<AlertEvent> winners = executor.invokeAll(inserts).stream()
                        .map(AlertServiceMongoIntegrationTest::await)
                        .flatMap(Optional::stream)
                        .toList();

                long firingCount = mongoDatabase.getCollection("alert_events")
                        .countDocuments(new Document("ruleId", "ups-input-voltage-low")
                                .append("deviceId", "ups-1")
                                .append("channel", "input_voltage")
                                .append("state", AlertEvent.STATE_FIRING));

                assertEquals(1L, firingCount);
                assertEquals(1, winners.size());
                AlertEvent winner = winners.getFirst();
                assertEquals(1L, winner.sequence());
                assertEquals(1L, sequenceCounter(mongoDatabase));

                AlertEvent adopted = service.findFiring("ups-input-voltage-low", "ups-1", "input_voltage")
                        .orElseThrow();
                assertEquals(winner.id(), adopted.id());
                assertEquals(winner.sequence(), adopted.sequence());
            } finally {
                executor.shutdownNow();
                inspector.getDatabase(database).drop();
            }
        }
    }

    @Test
    void resolvedHistoryIsUnlimitedWhileOnlyOneLifecycleFires() {
        String uri = System.getenv(INTEGRATION_URI_ENV);
        Assumptions.assumeTrue(uri != null && !uri.isBlank(),
                INTEGRATION_URI_ENV + " is required for MongoDB integration tests");
        String database = "omnivise_alert_test_" + UUID.randomUUID().toString().replace("-", "");

        try (MongoClient inspector = MongoClients.create(uri)) {
            var mongoDatabase = inspector.getDatabase(database);
            createFiringUniqueIndex(mongoDatabase);
            AlertService service = new AlertService(inspector,
                    mongoDatabase.getCollection("alert_events"),
                    mongoDatabase.getCollection("alert_sequences"));
            try {
                AlertEvent pending = pending(0);
                for (int i = 0; i < 3; i++) {
                    AlertEvent firing = service.insertFiring(pending).orElseThrow();
                    assertTrue(service.insertFiring(pending).isEmpty());
                    service.resolve(firing, 20.0, "2026-09-11T08:01:00Z").orElseThrow();
                }
                AlertEvent current = service.insertFiring(pending).orElseThrow();

                var events = mongoDatabase.getCollection("alert_events");
                assertEquals(3L, events.countDocuments(new Document("state", AlertEvent.STATE_RESOLVED)));
                assertEquals(1L, events.countDocuments(new Document("state", AlertEvent.STATE_FIRING)));
                assertEquals(7L, current.sequence());
                assertEquals(7L, sequenceCounter(mongoDatabase));
            } finally {
                inspector.getDatabase(database).drop();
            }
        }
    }

    @Test
    void concurrentEvaluatorsOnTheSameReadingsEmitEachTransitionOnce() throws Exception {
        String uri = System.getenv(INTEGRATION_URI_ENV);
        Assumptions.assumeTrue(uri != null && !uri.isBlank(),
                INTEGRATION_URI_ENV + " is required for MongoDB integration tests");
        String database = "omnivise_alert_test_" + UUID.randomUUID().toString().replace("-", "");

        try (MongoClient podA = MongoClients.create(uri); MongoClient podB = MongoClients.create(uri)) {
            var mongoDatabase = podA.getDatabase(database);
            createFiringUniqueIndex(mongoDatabase);
            List<AlertEvent> emitted = Collections.synchronizedList(new ArrayList<>());
            AlertEvaluator evaluatorA = evaluator(podA, database, emitted);
            AlertEvaluator evaluatorB = evaluator(podB, database, emitted);
            var executor = Executors.newFixedThreadPool(2);
            try {
                // Both replicas consume the same Change Stream event, concurrently.
                bothEvaluate(executor, evaluatorA, evaluatorB, 2.0);
                assertEquals(List.of(AlertEvent.STATE_FIRING), states(emitted));
                assertEquals(1L, firingCount(mongoDatabase));

                bothEvaluate(executor, evaluatorA, evaluatorB, 1.5);
                assertEquals(1, emitted.size());

                bothEvaluate(executor, evaluatorA, evaluatorB, 231.0);
                assertEquals(List.of(AlertEvent.STATE_FIRING, AlertEvent.STATE_RESOLVED), states(emitted));
                assertEquals(0L, firingCount(mongoDatabase));
                assertEquals(emitted.get(0).id(), emitted.get(1).id());

                bothEvaluate(executor, evaluatorA, evaluatorB, 3.0);
                assertEquals(List.of(AlertEvent.STATE_FIRING, AlertEvent.STATE_RESOLVED,
                        AlertEvent.STATE_FIRING), states(emitted));
                assertEquals(1L, firingCount(mongoDatabase));
                assertEquals(List.of(1L, 2L, 3L), emitted.stream().map(AlertEvent::sequence).toList());
                assertEquals(3L, sequenceCounter(mongoDatabase));
            } finally {
                executor.shutdownNow();
                podA.getDatabase(database).drop();
            }
        }
    }

    private static AlertEvaluator evaluator(MongoClient client, String database, List<AlertEvent> emitted) {
        var mongoDatabase = client.getDatabase(database);
        AlertService service = new AlertService(client,
                mongoDatabase.getCollection("alert_events"),
                mongoDatabase.getCollection("alert_sequences"));
        DeviceService devices = new DeviceService(List.of(new Document("deviceId", "ups-1")
                .append("name", "ups-1")
                .append("kind", "ups")
                .append("location", "Server Room")
                .append("channels", List.of(new Document("channel", "input_voltage").append("unit", "V")))));
        AlertRule rule = new AlertRule("ups-input-voltage-low", true,
                new AlertRule.Matcher("ups-1", null, "input_voltage"), "<", 180, 210, "critical");
        return new AlertEvaluator(service, List.of(rule), devices, mock(WebSocketHandler.class),
                emitted::add, () -> Instant.parse("2026-09-11T08:00:00Z"));
    }

    private static void bothEvaluate(ExecutorService executor, AlertEvaluator a, AlertEvaluator b,
            double value) throws InterruptedException {
        SensorReading reading = new SensorReading("ups-1", "input_voltage", value, "V",
                "2026-09-11T08:00:00Z");
        executor.invokeAll(List.<Callable<Void>>of(
                () -> {
                    a.evaluate(reading);
                    return null;
                },
                () -> {
                    b.evaluate(reading);
                    return null;
                })).forEach(AlertServiceMongoIntegrationTest::await);
    }

    private static List<String> states(List<AlertEvent> emitted) {
        return emitted.stream().map(AlertEvent::state).toList();
    }

    private static long firingCount(MongoDatabase database) {
        return database.getCollection("alert_events")
                .countDocuments(new Document("state", AlertEvent.STATE_FIRING));
    }

    private static long sequenceCounter(MongoDatabase database) {
        return database.getCollection("alert_sequences")
                .find(new Document("_id", "global")).first().getLong("value");
    }

    /** Mirrors FIRING_ALERT_UNIQUE_INDEX in mongo-init.js, which owns the schema. */
    private static void createFiringUniqueIndex(MongoDatabase database) {
        database.getCollection("alert_events").createIndex(
                Indexes.ascending("ruleId", "deviceId", "channel"),
                new IndexOptions()
                        .name("uniq_firing_rule_device_channel")
                        .unique(true)
                        .partialFilterExpression(Filters.eq("state", AlertEvent.STATE_FIRING)));
    }

    private static <T> T await(Future<T> future) {
        try {
            return future.get();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static AlertEvent pending(int index) {
        return new AlertEvent(null, 0, "rule-" + index, "device-" + index, "temperature",
                "warning", AlertEvent.STATE_FIRING, 31.0, 31.0,
                "2026-09-11T08:00:00Z", null);
    }
}
