package com.omnivise.webhook;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Set;

import com.omnivise.model.AlertEvent;

/**
 * Outbound notification for an alert state transition (issue #73).
 *
 * <p>Contract: {@link #dispatch} is <em>non-blocking</em> and <em>never
 * throws</em>. It is called from the single Change Stream evaluation thread on a
 * {@code firing} or {@code resolved} transition only — never for a repeated
 * breach. Delivery, failure logging and swallowing are the implementation's
 * concern; a slow or failing endpoint must not delay or break evaluation.
 */
public interface AlertWebhook {

    /** Fire-and-forget dispatch of one transition. Returns immediately; swallows all errors. */
    void dispatch(AlertEvent event);

    /**
     * Builds the webhook from the {@code ALERT_WEBHOOK_URL} value.
     *
     * <ul>
     *   <li>{@code null} / blank → a {@link DisabledAlertWebhook} (no outbound call ever);</li>
     *   <li>a non-blank, absolute {@code http}/{@code https} URL with a host →
     *       an {@link HttpAlertWebhook};</li>
     *   <li>anything else non-blank → {@link IllegalStateException} (a
     *       configuration error that must fail startup, never silently disable).</li>
     * </ul>
     */
    static AlertWebhook fromConfig(String rawUrl) {
        if (rawUrl == null || rawUrl.isBlank()) {
            return new DisabledAlertWebhook();
        }
        String trimmed = rawUrl.trim();
        try {
            URI uri = new URI(trimmed);
            String scheme = uri.getScheme();
            if (!uri.isAbsolute()
                    || scheme == null
                    || !Set.of("http", "https").contains(scheme.toLowerCase())
                    || uri.getHost() == null
                    || uri.getHost().isBlank()) {
                throw new IllegalStateException(
                        "invalid ALERT_WEBHOOK_URL '" + trimmed + "': expected an absolute http/https URL");
            }
            return new HttpAlertWebhook(uri);
        } catch (URISyntaxException e) {
            throw new IllegalStateException(
                    "invalid ALERT_WEBHOOK_URL '" + trimmed + "': " + e.getMessage(), e);
        }
    }
}
