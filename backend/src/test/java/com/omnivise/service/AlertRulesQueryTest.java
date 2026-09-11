package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.bson.Document;
import org.junit.jupiter.api.Test;

/**
 * A validated {@code GET /api/alerts/rules} query (issue #89).
 *
 * <p>{@code deviceId} is optional: absent or blank means "all devices", present
 * means the device must exist in the registry. Unlike {@link AlertQuery}, an
 * unknown {@code deviceId} here is a validation error, not a filter that
 * matches nothing — the endpoint must not silently return empty/unrelated data
 * for a typo'd device id.
 */
class AlertRulesQueryTest {

    private static DeviceService devices() {
        Document rack = new Document()
                .append("deviceId", "rack-a1")
                .append("name", "Rack A1")
                .append("kind", "rack")
                .append("location", "Server Room / Rack A1")
                .append("channels", List.of());
        return new DeviceService(List.of(rack));
    }

    @Test
    void absentDeviceIdIsValidWithNoDeviceSelected() {
        AlertRulesQuery.Result result = AlertRulesQuery.parse(null, devices());

        AlertRulesQuery.Valid valid = (AlertRulesQuery.Valid) result;
        assertNull(valid.deviceId());
        assertNull(valid.deviceKind());
    }

    @Test
    void blankDeviceIdBehavesLikeAnAbsentDeviceId() {
        AlertRulesQuery.Result result = AlertRulesQuery.parse("   ", devices());

        AlertRulesQuery.Valid valid = (AlertRulesQuery.Valid) result;
        assertNull(valid.deviceId());
        assertNull(valid.deviceKind());
    }

    @Test
    void aKnownDeviceIdResolvesItsKindFromTheRegistry() {
        AlertRulesQuery.Result result = AlertRulesQuery.parse("rack-a1", devices());

        AlertRulesQuery.Valid valid = (AlertRulesQuery.Valid) result;
        assertEquals("rack-a1", valid.deviceId());
        assertEquals("rack", valid.deviceKind());
    }

    @Test
    void anUnknownDeviceIdIsRejectedAsInvalidRequest() {
        AlertRulesQuery.Result result = AlertRulesQuery.parse("does-not-exist", devices());

        AlertRulesQuery.Invalid invalid = (AlertRulesQuery.Invalid) result;
        assertEquals("invalid_request", invalid.error());
        assertEquals("deviceId", invalid.field());
        assertTrue(invalid.message() != null && !invalid.message().isBlank());
    }
}
