package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.function.Consumer;

import org.bson.Document;
import org.bson.conversions.Bson;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import com.mongodb.client.FindIterable;
import com.mongodb.client.MongoCollection;
import com.omnivise.model.AlertEvent;

/**
 * Read access to {@code alert_events} for {@code GET /api/alerts} (issue #73).
 *
 * <p>MongoDB is mocked. These tests pin the filter document built for each
 * combination of the (already validated) {@code state}/{@code severity}/{@code
 * deviceId} filters, the newest-first sort, that the query {@code limit} is
 * applied, and that each document is mapped through {@code AlertEventMapper} in
 * the collection's order.
 */
@SuppressWarnings("unchecked")
class AlertServiceTest {

    private final MongoCollection<Document> collection = mock(MongoCollection.class);

    private static AlertQuery query(String state, String severity, String deviceId, String limit) {
        return assertInstanceOf(AlertQuery.Valid.class,
                AlertQuery.parse(state, severity, deviceId, limit)).query();
    }

    private void stubFind(List<Document> docs) {
        FindIterable<Document> iterable = mock(FindIterable.class);
        when(iterable.sort(any(Bson.class))).thenReturn(iterable);
        when(iterable.limit(anyInt())).thenReturn(iterable);
        doAnswer(inv -> {
            Consumer<Document> consumer = inv.getArgument(0);
            docs.forEach(consumer);
            return null;
        }).when(iterable).forEach(any(Consumer.class));
        when(collection.find(any(Bson.class))).thenReturn(iterable);
    }

    private static Document eventDoc(String id, String state, String severity, String deviceId) {
        return new Document("_id", new org.bson.types.ObjectId(id))
                .append("ruleId", "rule-" + deviceId)
                .append("deviceId", deviceId)
                .append("channel", "input_voltage")
                .append("severity", severity)
                .append("state", state)
                .append("triggeredValue", 2.0)
                .append("lastValue", 2.0)
                .append("startedAt", Date.from(Instant.parse("2026-09-10T08:00:00Z")));
    }

    // ------------------------------------------------------------------
    // Filter construction
    // ------------------------------------------------------------------

    @Test
    void noFiltersProduceAnEmptyQuery() {
        assertEquals(new Document(), AlertService.buildFilter(null, null, null));
    }

    @Test
    void eachFilterIsAppliedOnItsOwnField() {
        assertEquals(new Document("state", "firing"),
                AlertService.buildFilter("firing", null, null));
        assertEquals(new Document("severity", "critical"),
                AlertService.buildFilter(null, "critical", null));
        assertEquals(new Document("deviceId", "ups-1"),
                AlertService.buildFilter(null, null, "ups-1"));
    }

    @Test
    void allThreeFiltersAreCombined() {
        assertEquals(
                new Document("state", "resolved").append("severity", "warning").append("deviceId", "rack-a1"),
                AlertService.buildFilter("resolved", "warning", "rack-a1"));
    }

    @Test
    void newestFirstSortIsByStartedAtDescendingWithAStableIdTieBreaker() {
        assertEquals(-1, AlertService.SORT_NEWEST_FIRST.getInteger("startedAt"));
        assertEquals(-1, AlertService.SORT_NEWEST_FIRST.getInteger("_id"));
    }

    // ------------------------------------------------------------------
    // Query execution
    // ------------------------------------------------------------------

    @Test
    void findAppliesTheValidatedFilterSortAndLimitAndMapsEachDocument() {
        stubFind(List.of(
                eventDoc("64b7f000000000000000ff01", "firing", "critical", "ups-1"),
                eventDoc("64b7f000000000000000ff02", "firing", "critical", "ups-1")));

        List<AlertEvent> result = new AlertService(collection).find(query("firing", "critical", "ups-1", "25"));

        ArgumentCaptor<Bson> filter = ArgumentCaptor.forClass(Bson.class);
        verify(collection).find(filter.capture());
        assertEquals(
                new Document("state", "firing").append("severity", "critical").append("deviceId", "ups-1"),
                filter.getValue());

        FindIterable<Document> iterable = collection.find(filter.getValue());
        verify(iterable).sort(AlertService.SORT_NEWEST_FIRST);
        verify(iterable).limit(25);

        assertEquals(2, result.size());
        assertEquals("64b7f000000000000000ff01", result.get(0).id());
        assertEquals("firing", result.get(0).state());
        assertEquals("ups-1", result.get(1).deviceId());
    }

    @Test
    void findReturnsAnEmptyListWhenNothingMatches() {
        stubFind(List.of());
        assertEquals(List.of(), new AlertService(collection).find(query(null, null, null, null)));
    }
}
