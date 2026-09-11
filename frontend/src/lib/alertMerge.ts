import type { AlertEvent } from '../types/domain'

const RECENT_ALERTS_LIMIT = 20

/**
 * Merges one live alert transition into a "recent alerts" list (issue #75
 * live reaction). A known id is replaced in place, preserving its position
 * and the backend's newest-first ordering; a genuinely new id is inserted at
 * the front. Never duplicates a row for the same id.
 */
export function mergeRecentAlert(
  existing: AlertEvent[],
  incoming: AlertEvent,
  limit = RECENT_ALERTS_LIMIT,
): AlertEvent[] {
  const index = existing.findIndex((alert) => alert.id === incoming.id)
  if (index === -1) {
    return [incoming, ...existing].slice(0, limit)
  }
  const next = existing.slice()
  next[index] = incoming
  return next
}

/**
 * Merges one live alert transition into an "active alerts" list used for
 * device-status derivation: firing upserts by id, resolved removes by id.
 * Never keyed by ruleId/channel -- a later lifecycle can legitimately
 * produce a new alert id for the same rule/channel.
 */
export function mergeActiveAlert(existing: AlertEvent[], incoming: AlertEvent): AlertEvent[] {
  const withoutIncoming = existing.filter((alert) => alert.id !== incoming.id)
  return incoming.state === 'firing' ? [incoming, ...withoutIncoming] : withoutIncoming
}

/**
 * Replays alert transitions buffered while a REST snapshot request was in
 * flight (issue #75 M1 fix) on top of that snapshot, oldest-first, via
 * mergeActiveAlert. Because the merge is idempotent by id, replaying a
 * transition the snapshot already reflects is harmless.
 */
export function replayActiveAlerts(snapshot: AlertEvent[], buffered: AlertEvent[]): AlertEvent[] {
  return buffered.reduce((items, alert) => mergeActiveAlert(items, alert), snapshot)
}

/** Same idea as {@link replayActiveAlerts}, for the recent-alerts list. */
export function replayRecentAlerts(
  snapshot: AlertEvent[],
  buffered: AlertEvent[],
  limit = RECENT_ALERTS_LIMIT,
): AlertEvent[] {
  return buffered.reduce((items, alert) => mergeRecentAlert(items, alert, limit), snapshot)
}
