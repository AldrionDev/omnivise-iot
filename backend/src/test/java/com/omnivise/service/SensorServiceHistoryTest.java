package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.function.Consumer;

import org.bson.Document;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import com.mongodb.client.AggregateIterable;
import com.mongodb.client.MongoCollection;
import com.omnivise.model.SensorHistory;
import com.omnivise.service.SensorHistoryRequest.Valid;

/**
 * Response assembly for {@code GET /api/sensors/history} (issue #72).
 *
 * <p>MongoDB is mocked: {@code collection.aggregate(pipeline)} returns a
 * canned list of {@code $group} result documents. The tests check that
 * {@link SensorService#history} runs the pipeline from
 * {@link SensorService#buildHistoryPipeline}, maps each group document to a
 * point ({@code _id} bucket start -> ISO string, numeric {@code avg}/{@code min}
 * /{@code max}), keeps the aggregation's ascending order, and echoes the
 * device/channel/unit/bucket from the validated request. An empty aggregation
 * yields {@code points: []}, still with the surrounding metadata.
 */
@SuppressWarnings("unchecked")
class SensorServiceHistoryTest {

    private final MongoCollection<Document> collection = mock(MongoCollection.class);

    private static DeviceService registry() {
        Document rack = new Document()
                .append("deviceId", "rack-a1")
                .append("name", "Rack A1")
                .append("kind", "rack")
                .append("location", "Server Room / Rack A1")
                .append("channels", List.of(
                        new Document().append("channel", "intake_temp").append("unit", "°C"),
                        new Document().append("channel", "power_draw").append("unit", "W")));
        return new DeviceService(List.of(rack));
    }

    private static SensorHistoryRequest request(String channel, String bucket) {
        SensorHistoryRequest.Result result = SensorHistoryRequest.parse(
                "rack-a1", channel,
                "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", bucket,
                registry(), 1000);
        return assertInstanceOf(Valid.class, result).request();
    }

    private void stubAggregate(List<Document> groupDocs) {
        AggregateIterable<Document> iterable = mock(AggregateIterable.class);
        org.mockito.Mockito.doAnswer(inv -> {
            Consumer<Document> consumer = inv.getArgument(0);
            groupDocs.forEach(consumer);
            return null;
        }).when(iterable).forEach(org.mockito.ArgumentMatchers.any(Consumer.class));
        when(collection.aggregate(anyList())).thenReturn(iterable);
    }

    private static Document group(String iso, Number avg, Number min, Number max) {
        return new Document("_id", Date.from(Instant.parse(iso)))
                .append("avg", avg)
                .append("min", min)
                .append("max", max);
    }

    // ------------------------------------------------------------------

    @Test
    void mapsEachGroupDocumentToAPointInAggregationOrder() {
        stubAggregate(List.of(
                group("2026-09-10T08:00:00Z", 21.5, 21.4, 21.6),
                group("2026-09-10T08:05:00Z", 21.9, 21.8, 22.0)));

        SensorService service = new SensorService(collection);
        SensorHistory history = service.history(request("intake_temp", "5m"));

        assertEquals(2, history.points().size());

        SensorHistory.Point first = history.points().get(0);
        assertEquals("2026-09-10T08:00:00Z", first.t());
        assertEquals(21.5, first.avg());
        assertEquals(21.4, first.min());
        assertEquals(21.6, first.max());

        assertEquals("2026-09-10T08:05:00Z", history.points().get(1).t());
        assertEquals(21.9, history.points().get(1).avg());
    }

    @Test
    void echoesDeviceChannelUnitAndBucketFromTheValidatedRequest() {
        stubAggregate(List.of(group("2026-09-10T08:00:00Z", 1200.0, 1180.0, 1225.0)));

        SensorService service = new SensorService(collection);
        SensorHistory history = service.history(request("power_draw", "1h"));

        assertEquals("rack-a1", history.deviceId());
        assertEquals("power_draw", history.channel());
        assertEquals("W", history.unit());
        assertEquals("1h", history.bucket());
    }

    @Test
    void anEmptyAggregationYieldsEmptyPointsWithTheMetadataStillPresent() {
        stubAggregate(List.of());

        SensorService service = new SensorService(collection);
        SensorHistory history = service.history(request("intake_temp", "5m"));

        assertEquals("rack-a1", history.deviceId());
        assertEquals("intake_temp", history.channel());
        assertEquals("°C", history.unit());
        assertEquals("5m", history.bucket());
        assertTrue(history.points().isEmpty());
    }

    @Test
    void coercesIntegerAggregatesToDoubleAndKeepsANullAvgAsNull() {
        // A non-numeric channel: Mongo's $avg over strings is null; $min/$max are
        // absent. Integer-valued numeric aggregates arrive as Integer.
        Document intAggregates = group("2026-09-10T08:00:00Z", 1203, 1180, 1225);
        Document nullAvg = new Document("_id", Date.from(Instant.parse("2026-09-10T08:05:00Z")))
                .append("avg", null);
        stubAggregate(List.of(intAggregates, nullAvg));

        SensorService service = new SensorService(collection);
        SensorHistory history = service.history(request("power_draw", "5m"));

        assertEquals(1203.0, history.points().get(0).avg());
        assertEquals(1180.0, history.points().get(0).min());
        assertEquals(1225.0, history.points().get(0).max());

        assertNull(history.points().get(1).avg());
        assertNull(history.points().get(1).min());
    }

    @Test
    void runsExactlyThePipelineFromBuildHistoryPipeline() {
        stubAggregate(List.of());
        SensorHistoryRequest req = request("intake_temp", "5m");

        SensorService service = new SensorService(collection);
        service.history(req);

        ArgumentCaptor<List<Document>> captor = ArgumentCaptor.forClass(List.class);
        org.mockito.Mockito.verify(collection).aggregate(captor.capture());

        assertEquals(
                SensorService.buildHistoryPipeline(
                        req.deviceId(), req.channel(), req.from(), req.to(), req.bucket()),
                new ArrayList<>(captor.getValue()));
    }
}
