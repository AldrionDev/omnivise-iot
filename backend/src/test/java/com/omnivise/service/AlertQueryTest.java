package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

import com.omnivise.service.AlertQuery.Invalid;
import com.omnivise.service.AlertQuery.Result;
import com.omnivise.service.AlertQuery.Valid;

/**
 * Parsing and validation for {@code GET /api/alerts} (issue #73).
 *
 * <p>{@link AlertQuery#parse} is the single seam for the query rules: {@code
 * state}/{@code severity} against a fixed set, {@code limit} as an integer in
 * {@code [1, 500]} (default {@code 100}), {@code deviceId} free-form. It never
 * throws — a rejection is an {@link Invalid} carrying the structured
 * {@code {error:"invalid_request", field, message}} body, fail-fast. Blank
 * optional filters are treated as absent; an unknown {@code deviceId} is a valid
 * filter (it just matches nothing).
 */
class AlertQueryTest {

    private static Valid valid(String state, String severity, String deviceId, String limit) {
        Result result = AlertQuery.parse(state, severity, deviceId, limit);
        return assertInstanceOf(Valid.class, result);
    }

    private static Invalid invalid(String state, String severity, String deviceId, String limit) {
        Result result = AlertQuery.parse(state, severity, deviceId, limit);
        Invalid error = assertInstanceOf(Invalid.class, result);
        assertEquals("invalid_request", error.error());
        assertTrue(error.message() != null && !error.message().isBlank());
        return error;
    }

    @Test
    void allFiltersAbsentYieldsNoFiltersAndTheDefaultLimit() {
        AlertQuery q = valid(null, null, null, null).query();

        assertNull(q.state());
        assertNull(q.severity());
        assertNull(q.deviceId());
        assertEquals(100, q.limit());
    }

    @Test
    void blankOptionalFiltersAreTreatedAsAbsent() {
        AlertQuery q = valid("  ", "", "   ", "  ").query();

        assertNull(q.state());
        assertNull(q.severity());
        assertNull(q.deviceId());
        assertEquals(100, q.limit());
    }

    @Test
    void acceptsTheSupportedStateAndSeverityValuesAndAnyDeviceId() {
        AlertQuery q = valid("resolved", "warning", "no-such-device", "25").query();

        assertEquals("resolved", q.state());
        assertEquals("warning", q.severity());
        assertEquals("no-such-device", q.deviceId());
        assertEquals(25, q.limit());
    }

    @Test
    void acceptsTheMaximumLimit() {
        assertEquals(500, valid(null, null, null, "500").query().limit());
    }

    @Test
    void rejectsAnUnsupportedState() {
        assertEquals("state", invalid("pending", null, null, null).field());
    }

    @Test
    void rejectsAnUnsupportedSeverity() {
        assertEquals("severity", invalid(null, "fatal", null, null).field());
    }

    @Test
    void rejectsANonIntegerLimit() {
        assertEquals("limit", invalid(null, null, null, "lots").field());
    }

    @Test
    void rejectsALimitBelowOne() {
        assertEquals("limit", invalid(null, null, null, "0").field());
    }

    @Test
    void rejectsALimitAboveTheMaximum() {
        assertEquals("limit", invalid(null, null, null, "501").field());
    }

    @Test
    void forActiveFixesTheStateToFiring() {
        AlertQuery q = assertInstanceOf(Valid.class,
                AlertQuery.forActive("critical", null, "10")).query();

        assertEquals("firing", q.state());
        assertEquals("critical", q.severity());
        assertEquals(10, q.limit());
    }

    @Test
    void forActiveStillValidatesItsOtherParams() {
        Result result = AlertQuery.forActive("fatal", null, null);
        assertEquals("severity", assertInstanceOf(Invalid.class, result).field());
    }
}
