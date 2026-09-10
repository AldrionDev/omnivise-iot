package com.omnivise.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;

import org.bson.Document;
import org.junit.jupiter.api.Test;

import com.omnivise.service.SensorHistoryRequest.Invalid;
import com.omnivise.service.SensorHistoryRequest.Result;
import com.omnivise.service.SensorHistoryRequest.Valid;

/**
 * Parsing and validation for {@code GET /api/sensors/history} (issue #72).
 *
 * <p>{@link SensorHistoryRequest#parse} is the single seam for every request
 * rule: required params, ISO-8601 timestamps with an offset, a strictly
 * increasing range, an allowed {@code bucket} label, the approved maximum bucket
 * count, and existence of the device/channel in the registry. It returns a
 * {@link Valid} carrying the normalised query, or an {@link Invalid} carrying
 * the structured {@code {error, field, message}} body — validation is fail-fast
 * (first problem only) and never throws.
 *
 * <p>Per the approved contract every rejection carries the constant
 * {@code error == "invalid_request"}; {@code field} is the discriminator
 * (one of {@code deviceId}/{@code channel}/{@code from}/{@code to}/{@code bucket}
 * or {@code "range"}).
 */
class SensorHistoryRequestTest {

    private static final int MAX_BUCKETS = 1000;

    private static DeviceService registry() {
        Document rack = new Document()
                .append("deviceId", "rack-a1")
                .append("name", "Rack A1")
                .append("kind", "rack")
                .append("location", "Server Room / Rack A1")
                .append("channels", List.of(
                        new Document().append("channel", "intake_temp").append("unit", "°C"),
                        new Document().append("channel", "door_contact").append("unit", "state")));
        return new DeviceService(List.of(rack));
    }

    private static Result parse(String deviceId, String channel, String from, String to, String bucket) {
        return SensorHistoryRequest.parse(deviceId, channel, from, to, bucket, registry(), MAX_BUCKETS);
    }

    private static Invalid invalid(String deviceId, String channel, String from, String to, String bucket) {
        Result result = parse(deviceId, channel, from, to, bucket);
        Invalid error = assertInstanceOf(Invalid.class, result);
        assertEquals("invalid_request", error.error(), "every rejection uses the constant error code");
        assertTrue(error.message() != null && !error.message().isBlank(), "a human-readable message is always present");
        return error;
    }

    // ------------------------------------------------------------------
    // Valid request
    // ------------------------------------------------------------------

    @Test
    void aFullyValidRequestIsNormalisedIntoInstantsBucketAndResolvedUnit() {
        Result result = parse("rack-a1", "intake_temp",
                "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", "5m");

        SensorHistoryRequest request = assertInstanceOf(Valid.class, result).request();
        assertEquals("rack-a1", request.deviceId());
        assertEquals("intake_temp", request.channel());
        assertEquals("°C", request.unit());
        assertEquals(Instant.parse("2026-09-10T08:00:00Z"), request.from());
        assertEquals(Instant.parse("2026-09-10T09:00:00Z"), request.to());
        assertSame(Bucket.M5, request.bucket());
    }

    @Test
    void anIso8601TimestampWithANumericOffsetIsAccepted() {
        Result result = parse("rack-a1", "intake_temp",
                "2026-09-10T10:00:00+02:00", "2026-09-10T11:00:00+02:00", "1m");

        SensorHistoryRequest request = assertInstanceOf(Valid.class, result).request();
        assertEquals(Instant.parse("2026-09-10T08:00:00Z"), request.from());
        assertEquals(Instant.parse("2026-09-10T09:00:00Z"), request.to());
    }

    @Test
    void aBucketAlignedRangeExactlyAtTheMaxBucketCountIsAccepted() {
        // from is on a 1m boundary and the span is exactly 1000 minutes, so the
        // aggregation touches exactly 1000 aligned buckets == the limit.
        Result result = parse("rack-a1", "intake_temp",
                "2026-09-10T00:00:00Z", "2026-09-10T16:40:00Z", "1m");

        assertInstanceOf(Valid.class, result);
    }

    @Test
    void anUnalignedRangeThatStillTouchesAtMostTheLimitIsAccepted() {
        // from is 30s past a 1m boundary; the half-open range [00:00:30, 16:40:00)
        // truncates into 00:00 .. 16:39 == exactly 1000 aligned buckets.
        Result result = parse("rack-a1", "intake_temp",
                "2026-09-10T00:00:30Z", "2026-09-10T16:40:00Z", "1m");

        assertInstanceOf(Valid.class, result);
    }

    // ------------------------------------------------------------------
    // Missing parameters
    // ------------------------------------------------------------------

    @Test
    void aMissingDeviceIdIsRejected() {
        for (String missing : new String[] {null, "", "   "}) {
            Invalid error = invalid(missing, "intake_temp",
                    "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", "5m");
            assertEquals("deviceId", error.field());
        }
    }

    @Test
    void aMissingChannelIsRejected() {
        Invalid error = invalid("rack-a1", null,
                "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", "5m");
        assertEquals("channel", error.field());
    }

    @Test
    void aMissingFromIsRejected() {
        Invalid error = invalid("rack-a1", "intake_temp", "  ", "2026-09-10T09:00:00Z", "5m");
        assertEquals("from", error.field());
    }

    @Test
    void aMissingToIsRejected() {
        Invalid error = invalid("rack-a1", "intake_temp", "2026-09-10T08:00:00Z", null, "5m");
        assertEquals("to", error.field());
    }

    @Test
    void aMissingBucketIsRejected() {
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", null);
        assertEquals("bucket", error.field());
    }

    // ------------------------------------------------------------------
    // Invalid timestamps
    // ------------------------------------------------------------------

    @Test
    void aNonIsoFromIsRejectedAsAnInvalidTimestamp() {
        Invalid error = invalid("rack-a1", "intake_temp",
                "not-a-date", "2026-09-10T09:00:00Z", "5m");
        assertEquals("from", error.field());
        assertTrue(error.message().contains("ISO-8601"));
    }

    @Test
    void aDateOnlyToIsRejectedAsAnInvalidTimestamp() {
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T08:00:00Z", "2026-09-10", "5m");
        assertEquals("to", error.field());
    }

    @Test
    void aTimestampWithoutAZoneOffsetIsRejected() {
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T08:00:00", "2026-09-10T09:00:00Z", "5m");
        assertEquals("from", error.field());
    }

    // ------------------------------------------------------------------
    // Timestamps outside the BSON Date range (signed 64-bit epoch millis,
    // roughly +/-292 million years). OffsetDateTime parses years up to
    // +/-999,999,999, so these are well-formed ISO-8601 values that must still
    // be rejected with a structured 400 rather than escaping as an exception.
    // ------------------------------------------------------------------

    @Test
    void aWellFormedToBeyondTheBsonDateRangeIsRejectedAsAnInvalidTimestamp() {
        String farFuture = "+300000000-01-01T00:00:00Z";
        OffsetDateTime.parse(farFuture); // precondition: valid ISO-8601 with offset

        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T08:00:00Z", farFuture, "1m");
        assertEquals("to", error.field());
    }

    @Test
    void aWellFormedFromBeyondTheBsonDateRangeIsRejectedAsAnInvalidTimestamp() {
        String farPast = "-300000000-01-01T00:00:00Z";
        OffsetDateTime.parse(farPast); // precondition: valid ISO-8601 with offset

        Invalid error = invalid("rack-a1", "intake_temp",
                farPast, "2026-09-10T09:00:00Z", "1m");
        assertEquals("from", error.field());
    }

    @Test
    void aFarButRepresentableTimestampRangeIsStillAccepted() {
        // Year 200,000,000 is ~6.3e18 ms, inside the signed 64-bit millis range:
        // the range guard must not reject representable instants.
        Result result = parse("rack-a1", "intake_temp",
                "+200000000-01-01T00:00:00Z", "+200000000-01-01T01:00:00Z", "1m");

        SensorHistoryRequest request = assertInstanceOf(Valid.class, result).request();
        assertEquals(OffsetDateTime.parse("+200000000-01-01T00:00:00Z").toInstant(), request.from());
    }

    // ------------------------------------------------------------------
    // Reversed / empty range
    // ------------------------------------------------------------------

    @Test
    void aReversedRangeIsRejected() {
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T09:00:00Z", "2026-09-10T08:00:00Z", "5m");
        assertEquals("range", error.field());
    }

    @Test
    void anEqualFromAndToIsRejected() {
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T08:00:00Z", "2026-09-10T08:00:00Z", "5m");
        assertEquals("range", error.field());
    }

    // ------------------------------------------------------------------
    // Unsupported bucket
    // ------------------------------------------------------------------

    @Test
    void anUnsupportedBucketLabelIsRejectedWithTheAllowedSetInTheMessage() {
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", "2m");
        assertEquals("bucket", error.field());
        assertTrue(error.message().contains("[1m, 5m, 1h]"));
    }

    // ------------------------------------------------------------------
    // Too many buckets — measured against the ALIGNED $dateTrunc bucket count,
    // not ceil((to - from) / width).
    // ------------------------------------------------------------------

    @Test
    void aRangeBucketCombinationBeyondTheMaxBucketCountIsRejected() {
        // 48h / 1m bucket == 2880 buckets, well over the 1000 limit.
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T08:00:00Z", "2026-09-12T08:00:00Z", "1m");
        assertEquals("range", error.field());
        assertTrue(error.message().contains("1000"), "the message states the maximum");
    }

    @Test
    void aBucketAlignedRangeOneBucketOverTheLimitIsRejected() {
        // from on a boundary, span 1001 minutes -> 1001 aligned buckets.
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T00:00:00Z", "2026-09-10T16:41:00Z", "1m");
        assertEquals("range", error.field());
    }

    @Test
    void anUnalignedRangeOfExactlyTheLimitLengthIsRejectedBecauseItTruncatesIntoAnExtraBucket() {
        // Regression: from is 30s past a 1m boundary and the span is exactly
        // 1000 minutes. ceil(1000min / 1min) == 1000 would (wrongly) accept it,
        // but the half-open range [00:00:30, 16:40:30) truncates into
        // 00:00 .. 16:40 == 1001 aligned $dateTrunc buckets, one over the limit.
        Invalid error = invalid("rack-a1", "intake_temp",
                "2026-09-10T00:00:30Z", "2026-09-10T16:40:30Z", "1m");
        assertEquals("range", error.field());
        assertTrue(error.message().contains("1001"), "the message states the true bucket count");
    }

    @Test
    void anUnalignedPreEpochRangeOfExactlyTheLimitLengthIsRejected() {
        // Regression for floor semantics on negative epoch millis: from is 30s
        // BEFORE the epoch (-30000 ms, inside the 1969-12-31T23:59 bucket) and the
        // span is exactly 1000 minutes. [23:59:30, 16:39:30) truncates into
        // 1969-12-31T23:59 .. 1970-01-01T16:39 == 1001 aligned buckets. A
        // truncating division would place from in bucket 0 and count only 1000.
        Invalid error = invalid("rack-a1", "intake_temp",
                "1969-12-31T23:59:30Z", "1970-01-01T16:39:30Z", "1m");
        assertEquals("range", error.field());
        assertTrue(error.message().contains("1001"), "the message states the true bucket count");
    }

    // ------------------------------------------------------------------
    // Unknown device / channel
    // ------------------------------------------------------------------

    @Test
    void anUnknownDeviceIsRejected() {
        Invalid error = invalid("no-such-device", "intake_temp",
                "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", "5m");
        assertEquals("deviceId", error.field());
    }

    @Test
    void anUnknownChannelOnAKnownDeviceIsRejected() {
        Invalid error = invalid("rack-a1", "no_such_channel",
                "2026-09-10T08:00:00Z", "2026-09-10T09:00:00Z", "5m");
        assertEquals("channel", error.field());
    }
}
