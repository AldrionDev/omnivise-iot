package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Instant;
import java.util.Date;
import java.util.List;

import org.bson.Document;
import org.junit.jupiter.api.Test;

/**
 * Aggregation pipeline construction for {@code GET /api/sensors/history}
 * (issue #72).
 *
 * <p>These tests pin the exact BSON pipeline produced for a history query so the
 * {@code $match} -> {@code $group}/{@code $dateTrunc} -> {@code $sort} contract
 * is verified without a live MongoDB. The stored {@code timestamp} is a BSON
 * {@code Date}, so the range bounds must be {@link Date} instances and the range
 * must be half-open ({@code $gte} lower, {@code $lt} upper).
 */
class SensorServiceHistoryPipelineTest {

    private static final Instant FROM = Instant.parse("2026-09-10T08:00:00Z");
    private static final Instant TO = Instant.parse("2026-09-10T09:00:00Z");

    @Test
    void pipelineHasMatchThenGroupThenSortInThatOrder() {
        List<Document> pipeline =
                SensorService.buildHistoryPipeline("rack-a1", "intake_temp", FROM, TO, Bucket.M5);

        assertEquals(3, pipeline.size());
        assertTrue(pipeline.get(0).containsKey("$match"), "stage 1 must be $match");
        assertTrue(pipeline.get(1).containsKey("$group"), "stage 2 must be $group");
        assertTrue(pipeline.get(2).containsKey("$sort"), "stage 3 must be $sort");
    }

    @Test
    void matchStageFiltersOnDeviceChannelAndAHalfOpenDateRange() {
        List<Document> pipeline =
                SensorService.buildHistoryPipeline("rack-a1", "intake_temp", FROM, TO, Bucket.M5);

        Document match = pipeline.get(0).get("$match", Document.class);

        assertEquals("rack-a1", match.getString("deviceId"));
        assertEquals("intake_temp", match.getString("channel"));

        Document range = match.get("timestamp", Document.class);
        assertEquals(Date.from(FROM), range.get("$gte"));
        assertEquals(Date.from(TO), range.get("$lt"));
        assertTrue(range.get("$gte") instanceof Date, "range bounds must be BSON Date");
    }

    @Test
    void groupStageBucketsByDateTruncUsingTheRequestedBucketWidth() {
        List<Document> pipeline =
                SensorService.buildHistoryPipeline("rack-a1", "intake_temp", FROM, TO, Bucket.M5);

        Document group = pipeline.get(1).get("$group", Document.class);
        Document id = group.get("_id", Document.class);
        Document dateTrunc = id.get("$dateTrunc", Document.class);

        assertEquals("$timestamp", dateTrunc.getString("date"));
        assertEquals("minute", dateTrunc.getString("unit"));
        assertEquals(5, dateTrunc.getInteger("binSize"));
    }

    @Test
    void groupStageAggregatesAvgMinMaxOfValue() {
        List<Document> pipeline =
                SensorService.buildHistoryPipeline("rack-a1", "intake_temp", FROM, TO, Bucket.H1);

        Document group = pipeline.get(1).get("$group", Document.class);

        assertEquals("$value", group.get("avg", Document.class).getString("$avg"));
        assertEquals("$value", group.get("min", Document.class).getString("$min"));
        assertEquals("$value", group.get("max", Document.class).getString("$max"));
    }

    @Test
    void sortStageOrdersAscendingByBucketStart() {
        List<Document> pipeline =
                SensorService.buildHistoryPipeline("rack-a1", "intake_temp", FROM, TO, Bucket.H1);

        assertEquals(1, pipeline.get(2).get("$sort", Document.class).getInteger("_id"));
    }

    @Test
    void oneHourBucketMapsToDateTruncHour() {
        List<Document> pipeline =
                SensorService.buildHistoryPipeline("rack-a1", "intake_temp", FROM, TO, Bucket.H1);

        Document dateTrunc = pipeline.get(1)
                .get("$group", Document.class)
                .get("_id", Document.class)
                .get("$dateTrunc", Document.class);

        assertEquals("hour", dateTrunc.getString("unit"));
        assertEquals(1, dateTrunc.getInteger("binSize"));
    }
}
