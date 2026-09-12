package com.omnivise.webhook;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.CompletionException;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.omnivise.model.AlertEvent;

/**
 * The configured outbound webhook (issue #73): on every {@code firing} /
 * {@code resolved} transition it POSTs a compact JSON payload to
 * {@code ALERT_WEBHOOK_URL}.
 *
 * <p>Delivery is asynchronous via a {@link WebhookSender} (JDK
 * {@link HttpClient#sendAsync} in production) — {@link #dispatch} returns
 * immediately and never calls {@code join()}/{@code get()}. Connect timeout
 * ~2s, request timeout ~5s, no retries, no scheduler, no executor framework.
 * Transport failures, non-2xx responses and synchronous setup failures are all
 * logged and swallowed; a webhook problem can never delay or break evaluation.
 */
public final class HttpAlertWebhook implements AlertWebhook {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(2);
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(5);

    private final URI url;
    private final WebhookSender sender;

    /** Production wiring: a JDK {@link HttpClient}-backed async sender. */
    public HttpAlertWebhook(URI url) {
        this(url, jdkSender());
    }

    /** Test seam: inject the async transport. */
    public HttpAlertWebhook(URI url, WebhookSender sender) {
        this.url = url;
        this.sender = sender;
    }

    @Override
    public void dispatch(AlertEvent event) {
        try {
            sender.send(url, buildPayload(event)).whenComplete((ignored, error) -> {
                if (error != null) {
                    System.err.println("⚠️ Alert webhook POST failed for " + event.ruleId()
                            + ": " + rootMessage(error));
                }
            });
        } catch (RuntimeException e) {
            System.err.println("⚠️ Alert webhook dispatch failed for " + event.ruleId() + ": " + e);
        }
    }

    /**
     * The approved compact payload. {@code value} is {@code triggeredValue} on a
     * firing transition and {@code lastValue} on a resolved one; {@code
     * resolvedAt} is present only when resolved.
     */
    static String buildPayload(AlertEvent event) {
        boolean resolved = AlertEvent.STATE_RESOLVED.equals(event.state());
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("event", event.state());
        payload.put("ruleId", event.ruleId());
        payload.put("severity", event.severity());
        payload.put("deviceId", event.deviceId());
        payload.put("channel", event.channel());
        payload.put("value", resolved ? event.lastValue() : event.triggeredValue());
        payload.put("startedAt", event.startedAt());
        if (resolved) {
            payload.put("resolvedAt", event.resolvedAt());
        }
        payload.put("alertId", event.id());
        try {
            return MAPPER.writeValueAsString(payload);
        } catch (Exception e) {
            throw new IllegalStateException("failed to build alert webhook payload", e);
        }
    }

    private static WebhookSender jdkSender() {
        HttpClient client = HttpClient.newBuilder().connectTimeout(CONNECT_TIMEOUT).build();
        return (uri, body) -> {
            HttpRequest request = HttpRequest.newBuilder(uri)
                    .timeout(REQUEST_TIMEOUT)
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .build();
            return client.sendAsync(request, HttpResponse.BodyHandlers.discarding())
                    .thenApply(response -> {
                        if (response.statusCode() >= 300) {
                            throw new CompletionException(
                                    new IOException("HTTP " + response.statusCode()));
                        }
                        return null;
                    });
        };
    }

    private static String rootMessage(Throwable error) {
        Throwable cause = error;
        while (cause.getCause() != null && cause.getCause() != cause) {
            cause = cause.getCause();
        }
        return cause.getClass().getSimpleName() + ": " + cause.getMessage();
    }
}
