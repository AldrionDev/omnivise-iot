package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.Executors;

import org.bson.Document;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.omnivise.model.AlertEvent;

/** Replica-set integration coverage for the transaction guarantees introduced by issue #94. */
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
                    inserts.add(() -> service.insertFiring(pending(index)));
                }
                List<AlertEvent> firing = executor.invokeAll(inserts).stream()
                        .map(future -> {
                            try {
                                return future.get();
                            } catch (Exception e) {
                                throw new IllegalStateException(e);
                            }
                        })
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

    private static AlertEvent pending(int index) {
        return new AlertEvent(null, 0, "rule-" + index, "device-" + index, "temperature",
                "warning", AlertEvent.STATE_FIRING, 31.0, 31.0,
                "2026-09-11T08:00:00Z", null);
    }
}
