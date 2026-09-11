import { useEffect, useRef } from 'react'
import { useLiveStreamContext } from './LiveStreamContext'
import type { AlertEvent } from '../types/domain'

/**
 * Calls `onAlert` once for each new alert transition delivered over the #74
 * WebSocket buffer (LiveStreamContext.alerts), oldest-first, exactly once
 * per transition -- including when multiple land in the same array update.
 *
 * The buffer is newest-first and capped; this hook finds the boundary
 * between "already seen" and "new" by referential identity of the
 * previously-newest item, so it never re-delivers an already-applied
 * transition and needs no knowledge of the buffer's cap or clearing
 * behavior. On every disconnect #74 clears the buffer to `[]` (transitions
 * may have been missed) -- that reset is picked up here too, so the next
 * connected period starts clean; recovering the missed transitions is the
 * REST resync's job (see useReconnectResync), not this hook's.
 */
export function useLiveAlertTransitions(onAlert: (alert: AlertEvent) => void): void {
  const { alerts } = useLiveStreamContext()
  const lastSeenRef = useRef<AlertEvent | null>(null)
  const onAlertRef = useRef(onAlert)

  useEffect(() => {
    onAlertRef.current = onAlert
  })

  useEffect(() => {
    if (alerts.length === 0) {
      lastSeenRef.current = null
      return
    }

    const boundary = lastSeenRef.current
    const fresh: AlertEvent[] = []
    for (const item of alerts) {
      if (boundary && item === boundary) {
        break
      }
      fresh.push(item)
    }
    lastSeenRef.current = alerts[0]

    for (let i = fresh.length - 1; i >= 0; i--) {
      onAlertRef.current(fresh[i])
    }
  }, [alerts])
}
