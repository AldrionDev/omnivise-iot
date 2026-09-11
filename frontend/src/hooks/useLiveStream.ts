import { useEffect, useRef, useState } from 'react'
import { parseLiveEnvelope } from '../lib/parseLiveEnvelope'
import { resolveWebSocketUrl } from '../lib/resolveWebSocketUrl'
import type { AlertEvent, ConnectionState, Reading } from '../types/domain'

const INITIAL_RETRY_DELAY_MS = 1000
const RETRY_MULTIPLIER = 2
const MAX_RETRY_DELAY_MS = 10_000
const MAX_LIVE_ALERTS = 20

export interface LiveStreamState {
  connectionState: ConnectionState
  /** Latest reading per device/channel, keyed by `${deviceId}::${channel}`. */
  latestReadings: Record<string, Reading>
  /**
   * A small, bounded buffer of live alert transitions (newest first). This is
   * NOT historical or authoritative alert state -- it is cleared on every
   * disconnect because a missed interval means transitions may have been
   * missed too. #75/#76 own the authoritative REST-backed alert view.
   */
  alerts: AlertEvent[]
}

function readingKey(reading: Reading): string {
  return `${reading.deviceId}::${reading.channel}`
}

/**
 * Owns the single WebSocket connection to /ws/sensors for the whole app.
 * Call this exactly once (from AppShell) and share the result via
 * LiveStreamContext -- a second call opens a second, redundant socket.
 */
export function useLiveStream(): LiveStreamState {
  const [connectionState, setConnectionState] = useState<ConnectionState>('connecting')
  const [latestReadings, setLatestReadings] = useState<Record<string, Reading>>({})
  const [alerts, setAlerts] = useState<AlertEvent[]>([])

  const wsRef = useRef<WebSocket | null>(null)
  const reconnectTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const retryDelayRef = useRef(INITIAL_RETRY_DELAY_MS)

  useEffect(() => {
    // Effect-instance-local lifecycle flag -- NOT a ref. React StrictMode
    // (dev only) intentionally runs mount -> cleanup -> mount on this effect.
    // A single ref shared across both effect instances (the previous design)
    // gets reset by the second mount before the first socket's asynchronous
    // close event arrives, letting that stale close schedule a duplicate
    // reconnect and leaving two sockets open at once. `disposed` lives only
    // in this effect instance's closure, so an earlier instance's cleanup
    // can never be undone by a later instance's mount.
    let disposed = false

    function connect() {
      const url = resolveWebSocketUrl(window.location, import.meta.env.VITE_WS_URL)
      const ws = new WebSocket(url)
      wsRef.current = ws
      let closeHandled = false

      // A handler is stale -- and must be ignored -- once this effect
      // instance has been disposed, or once a later connect() call (a
      // reconnect, or a later StrictMode effect instance) has replaced this
      // socket as the current one. Either condition alone is enough; both
      // are checked because disposal and replacement can happen through
      // different paths (a real final unmount vs. a superseding reconnect).
      function isStale() {
        return disposed || wsRef.current !== ws
      }

      ws.onopen = () => {
        if (isStale()) {
          return
        }
        retryDelayRef.current = INITIAL_RETRY_DELAY_MS
        setConnectionState('connected')
      }

      ws.onmessage = (event) => {
        if (isStale()) {
          return
        }
        const envelope = parseLiveEnvelope(event.data)
        if (!envelope) {
          return
        }
        if (envelope.kind === 'reading') {
          setLatestReadings((prev) => ({ ...prev, [readingKey(envelope.payload)]: envelope.payload }))
        } else {
          setAlerts((prev) => [envelope.payload, ...prev].slice(0, MAX_LIVE_ALERTS))
        }
      }

      ws.onclose = () => {
        // closeHandled also guards against the same socket's close event
        // somehow being delivered more than once (not a real browser
        // scenario, but defensive against a misbehaving environment).
        if (isStale() || closeHandled) {
          return
        }
        closeHandled = true

        setConnectionState('reconnecting')
        setLatestReadings({})
        setAlerts([])

        const delay = retryDelayRef.current
        retryDelayRef.current = Math.min(delay * RETRY_MULTIPLIER, MAX_RETRY_DELAY_MS)
        reconnectTimeoutRef.current = setTimeout(connect, delay)
      }

      // A WebSocket error is always followed by a close event per spec;
      // onclose alone drives reconnect so retries are never scheduled twice.
      ws.onerror = () => {
        if (isStale()) {
          return
        }
      }
    }

    connect()

    return () => {
      disposed = true
      if (reconnectTimeoutRef.current !== null) {
        clearTimeout(reconnectTimeoutRef.current)
        reconnectTimeoutRef.current = null
      }
      wsRef.current?.close()
    }
    // Intentionally one-time per effect instance: exactly one socket for its
    // lifetime (see the StrictMode note on `disposed` above).
  }, [])

  return { connectionState, latestReadings, alerts }
}
