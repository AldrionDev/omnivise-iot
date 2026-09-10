package com.omnivise.webhook;

import java.net.URI;
import java.util.concurrent.CompletionStage;

/**
 * The asynchronous transport under {@link HttpAlertWebhook} (issue #73).
 *
 * <p>{@link #send} must return immediately: the caller (the Change Stream
 * evaluation thread) never blocks on the result. Transport failure and any
 * non-2xx response are surfaced as an exceptional completion of the returned
 * stage — {@link HttpAlertWebhook} attaches the logging/swallowing and never
 * calls {@code join()}/{@code get()}.
 */
public interface WebhookSender {

    CompletionStage<Void> send(URI url, String jsonBody);
}
