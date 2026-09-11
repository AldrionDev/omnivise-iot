const MINUTE_MS = 60_000
const HOUR_MS = 60 * MINUTE_MS
const DAY_MS = 24 * HOUR_MS

/**
 * Deterministic relative-time label ("5m ago", "3h ago", "2d ago") given an
 * explicit `now` -- callers own the clock (e.g. a page-level tick), so this
 * has no wall-clock dependency and needs no per-row timer.
 *
 * A future timestamp (clock skew between client and server) reads as
 * "just now" rather than a nonsensical negative duration.
 */
export function formatRelativeTime(iso: string, now: Date): string {
  const diffMs = now.getTime() - new Date(iso).getTime()

  if (diffMs < MINUTE_MS) {
    return 'just now'
  }
  if (diffMs < HOUR_MS) {
    return `${Math.floor(diffMs / MINUTE_MS)}m ago`
  }
  if (diffMs < DAY_MS) {
    return `${Math.floor(diffMs / HOUR_MS)}h ago`
  }
  return `${Math.floor(diffMs / DAY_MS)}d ago`
}
