package com.omnivise.mapper;

import java.time.Instant;
import java.util.Date;

import org.bson.Document;

import com.omnivise.model.SensorReading;

/**
 * The single {@code Document -> SensorReading} mapper (issue #70).
 *
 * <p>Both the REST read path ({@code SensorService}) and the live path
 * ({@code SensorChangeStreamListener}) go through here, so the reading shape is
 * defined in exactly one place.
 *
 * <p>It understands only the post-cutover {@code deviceId}/{@code channel}
 * schema. A stored BSON {@code Date} timestamp is normalised to an ISO-8601 UTC
 * string; {@code value} is passed through untouched so numeric and boolean
 * channels keep their type.
 */
public final class SensorReadingMapper {

    private SensorReadingMapper() {
    }

    public static SensorReading fromDocument(Document doc) {
        return new SensorReading(
                doc.getString("deviceId"),
                doc.getString("channel"),
                doc.get("value"),
                doc.getString("unit"),
                toIsoTimestamp(doc.get("timestamp")));
    }

    private static String toIsoTimestamp(Object timestamp) {
        if (timestamp == null) {
            return null;
        }
        if (timestamp instanceof Date date) {
            return date.toInstant().toString();
        }
        if (timestamp instanceof Instant instant) {
            return instant.toString();
        }
        return timestamp.toString();
    }
}
