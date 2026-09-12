package com.omnivise.webhook;

import com.omnivise.model.AlertEvent;

/**
 * The webhook when {@code ALERT_WEBHOOK_URL} is unset or blank (issue #73):
 * {@link #dispatch} does nothing and no outbound call is ever made.
 */
public final class DisabledAlertWebhook implements AlertWebhook {

    @Override
    public void dispatch(AlertEvent event) {
        // intentionally no-op
    }
}
