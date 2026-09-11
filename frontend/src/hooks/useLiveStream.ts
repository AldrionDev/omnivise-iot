import { useCallback, useEffect, useRef, useState } from 'react'
import { parseLiveEnvelope } from '../lib/parseLiveEnvelope'
import { resolveWebSocketUrl } from '../lib/resolveWebSocketUrl'
import type { AlertEvent, ConnectionState, Reading } from '../types/domain'

const INITIAL_RETRY_DELAY_MS = 1000
const RETRY_MULTIPLIER = 2
const MAX_RETRY_DELAY_MS = 10_000

export type AlertSubscriber = (alert: AlertEvent) => void

export interface LiveStreamState {
  connectionState: ConnectionState
  /** Latest reading per device/channel, keyed by `${deviceId}::${channel}`. */
  latestReadings: Record<string, Reading>
  /** Stable, lossless direct delivery for validated alert transitions. */
  subscribeToAlerts: (subscriber: AlertSubscriber) => () => void
}

function readingKey(reading: Reading): string {
  return `${reading.deviceId}::${reading.channel}`
}

/** Owns the application's single WebSocket connection. */
export function useLiveStream(): LiveStreamState {
  const [connectionState, setConnectionState] = useState<ConnectionState>('connecting')
  const [latestReadings, setLatestReadings] = useState<Record<string, Reading>>({})
  const subscribersRef = useRef(new Set<AlertSubscriber>())
  const wsRef = useRef<WebSocket | null>(null)
  const reconnectTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const retryDelayRef = useRef(INITIAL_RETRY_DELAY_MS)

  const subscribeToAlerts = useCallback((subscriber: AlertSubscriber) => {
    subscribersRef.current.add(subscriber)
    return () => subscribersRef.current.delete(subscriber)
  }, [])

  useEffect(() => {
    let disposed = false

    function connect() {
      const url = resolveWebSocketUrl(window.location, import.meta.env.VITE_WS_URL)
      const ws = new WebSocket(url)
      wsRef.current = ws
      let closeHandled = false
      const isStale = () => disposed || wsRef.current !== ws

      ws.onopen = () => {
        if (isStale()) return
        retryDelayRef.current = INITIAL_RETRY_DELAY_MS
        setConnectionState('connected')
      }

      ws.onmessage = (event) => {
        if (isStale()) return
        const envelope = parseLiveEnvelope(event.data)
        if (!envelope) return
        if (envelope.kind === 'reading') {
          setLatestReadings((prev) => ({ ...prev, [readingKey(envelope.payload)]: envelope.payload }))
          return
        }
        for (const subscriber of subscribersRef.current) {
          subscriber(envelope.payload)
        }
      }

      ws.onclose = () => {
        if (isStale() || closeHandled) return
        closeHandled = true
        setConnectionState('reconnecting')
        setLatestReadings({})
        const delay = retryDelayRef.current
        retryDelayRef.current = Math.min(delay * RETRY_MULTIPLIER, MAX_RETRY_DELAY_MS)
        reconnectTimeoutRef.current = setTimeout(connect, delay)
      }

      ws.onerror = () => undefined
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
  }, [])

  return { connectionState, latestReadings, subscribeToAlerts }
}
