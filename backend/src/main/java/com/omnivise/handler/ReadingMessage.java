package com.omnivise.handler;

import com.omnivise.model.SensorReading;

/**
 * Typed WebSocket envelope for a live sensor reading (issue #70).
 *
 * <p>Serialises as {@code { "kind": "reading", "payload": { ...reading... } }}.
 * The {@code kind} discriminator lets later message types (e.g. alerts) share
 * the same socket without ambiguity.
 */
public record ReadingMessage(String kind, SensorReading payload) {

    private static final String KIND = "reading";

    public static ReadingMessage of(SensorReading reading) {
        return new ReadingMessage(KIND, reading);
    }
}
