import { useEffect, useRef, useState } from 'react'
import { useLiveAlertTransitions } from './useLiveAlertTransitions'
import { useReconnectResync } from './useReconnectResync'
import { mergeActiveAlert, mergeRecentAlert, replayActiveAlerts, replayRecentAlerts } from '../lib/alertMerge'
import { fetchJson } from '../lib/api'
import type { AlertEvent } from '../types/domain'

export type AlertsSnapshotState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; items: AlertEvent[] }

/**
 * `'active'` upserts/removes by id (device-status derivation, no cap);
 * `'recent'` upserts in place / inserts new ids at the front, capped at
 * `limit` (a lifecycle table, e.g. the Alerts page).
 */
export type AlertsSnapshotKind = 'active' | 'recent'

/**
 * Fetches an authoritative alerts snapshot from `path` and keeps it live via
 * the #74 WebSocket buffer (issue #75/#76 architecture): a transition that
 * arrives while the snapshot fetch is in flight is buffered and replayed on
 * top of it once it resolves (never lost, never applied out of order), and a
 * reconnect (#74 clears its live buffer on every disconnect) triggers exactly
 * one authoritative refetch. Shared by OverviewPage (`'active'`) and
 * AlertsPage (`'recent'`) so this race-sensitive logic exists exactly once.
 */
export function useAlertsSnapshot(
  path: string,
  kind: AlertsSnapshotKind,
  limit = 20,
): AlertsSnapshotState {
  const [state, setState] = useState<AlertsSnapshotState>({ status: 'loading' })
  const resyncToken = useReconnectResync()
  const bufferRef = useRef<AlertEvent[]>([])
  const inFlightRef = useRef(true)

  useEffect(() => {
    let current = true
    bufferRef.current = []
    inFlightRef.current = true

    fetchJson<AlertEvent[]>(path)
      .then((items) => {
        if (!current) {
          return
        }
        const replayed =
          kind === 'active'
            ? replayActiveAlerts(items, bufferRef.current)
            : replayRecentAlerts(items, bufferRef.current, limit)
        bufferRef.current = []
        inFlightRef.current = false
        setState({ status: 'loaded', items: replayed })
      })
      .catch(() => {
        if (!current) {
          return
        }
        // Snapshot-and-clear happens here, not inside the setState updater --
        // a setState updater must be pure (React may invoke it more than
        // once, e.g. under StrictMode), so reading/clearing a ref from
        // inside it would make the first invocation's clear invisible to the
        // second, silently dropping the buffered transitions (issue #75 B1).
        const buffered = bufferRef.current
        bufferRef.current = []
        inFlightRef.current = false
        setState((prev) => {
          if (prev.status !== 'loaded') {
            return { status: 'error' }
          }
          const items =
            kind === 'active'
              ? replayActiveAlerts(prev.items, buffered)
              : replayRecentAlerts(prev.items, buffered, limit)
          return { status: 'loaded', items }
        })
      })

    return () => {
      current = false
    }
    // resyncToken: after a reconnect, #74 clears its live alert buffer (a
    // transition may have been missed while down) -- re-fetch the
    // authoritative snapshot.
  }, [path, kind, limit, resyncToken])

  useLiveAlertTransitions((alert) => {
    if (inFlightRef.current) {
      bufferRef.current.push(alert)
      return
    }
    setState((prev) => {
      if (prev.status !== 'loaded') {
        return prev
      }
      const items = kind === 'active' ? mergeActiveAlert(prev.items, alert) : mergeRecentAlert(prev.items, alert, limit)
      return { status: 'loaded', items }
    })
  })

  return state
}
