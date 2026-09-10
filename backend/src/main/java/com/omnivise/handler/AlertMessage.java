package com.omnivise.handler;

import com.omnivise.model.AlertEvent;

/**
 * Typed WebSocket envelope for an alert state transition (issue #73).
 *
 * <p>Serialises as {@code { "kind": "alert", "payload": { ...alert_event... } }},
 * sharing {@code /ws/sensors} with {@link ReadingMessage} via the {@code kind}
 * discriminator. Emitted only on {@code firing} and {@code resolved}
 * transitions, never on a repeated breach.
 */
public record AlertMessage(String kind, AlertEvent payload) {

    private static final String KIND = "alert";

    public static AlertMessage of(AlertEvent event) {
        return new AlertMessage(KIND, event);
    }
}
