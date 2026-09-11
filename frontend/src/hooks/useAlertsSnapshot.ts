import { useEffect, useRef, useState } from 'react'
import { useLiveAlertTransitions } from './useLiveAlertTransitions'
import { useReconnectResync } from './useReconnectResync'
import {
  mergeAlert,
  replayAlerts,
  selectActiveAlerts,
  selectRecentAlerts,
  type AlertStore,
} from '../lib/alertMerge'
import { fetchAlertsSnapshot } from '../lib/api'
import type { AlertEvent } from '../types/domain'

export type AlertsSnapshotState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; items: AlertEvent[] }

export type AlertsSnapshotKind = 'active' | 'recent'

const MAX_RETAINED_ALERT_IDS = 1000

interface LoadedState {
  scope: string
  status: 'loaded'
  store: AlertStore
}

type InternalState = { scope: string; status: 'loading' | 'error' } | LoadedState

interface ScopeSync {
  watermark: number | null
  journal: AlertEvent[]
  requestInFlight: boolean
  retainedIds: Set<string>
  compactionRequested: boolean
}

/**
 * Owns all REST/live synchronization for one alert scope. The journal belongs
 * to the scope, not a request; only an accepted snapshot consumes entries at
 * or below its atomic watermark. Resolved events remain as hidden tombstones
 * in active stores so stale firing frames cannot resurrect them.
 */
export function useAlertsSnapshot(
  path: string,
  kind: AlertsSnapshotKind,
  limit = 20,
  deviceId?: string,
  refreshToken = 0,
): AlertsSnapshotState {
  const scope = `${kind}:${limit}:${deviceId ?? '*'}:${path}`
  const [state, setState] = useState<InternalState>({ scope, status: 'loading' })
  const [compactionToken, setCompactionToken] = useState(0)
  const resyncToken = useReconnectResync()
  const generationRef = useRef(0)
  const syncByScopeRef = useRef(new Map<string, ScopeSync>())

  useEffect(() => {
    const generation = ++generationRef.current
    const controller = new AbortController()
    let sync = syncByScopeRef.current.get(scope)
    if (!sync) {
      sync = {
        watermark: null,
        journal: [],
        requestInFlight: true,
        retainedIds: new Set(),
        compactionRequested: false,
      }
      syncByScopeRef.current.set(scope, sync)
    } else {
      sync.requestInFlight = true
    }
    fetchAlertsSnapshot(path, controller.signal)
      .then(({ items, watermark }) => {
        if (generation !== generationRef.current || controller.signal.aborted) return
        const currentSync = syncByScopeRef.current.get(scope)
        if (!currentSync) return
        if (currentSync.watermark !== null && watermark < currentSync.watermark) {
          currentSync.requestInFlight = false
          currentSync.compactionRequested = false
          return
        }

        const store = replayAlerts(items, currentSync.journal, watermark)
        currentSync.watermark = watermark
        currentSync.requestInFlight = false
        // Only transitions covered by this authoritative snapshot are
        // consumed. Newer replayed entries remain available until a later
        // watermark covers them; stale/failed requests never reach this point.
        currentSync.journal = currentSync.journal.filter((event) => event.sequence > watermark)
        currentSync.retainedIds = new Set(store.order)
        currentSync.compactionRequested = false
        setState({ scope, status: 'loaded', store })
      })
      .catch(() => {
        if (generation !== generationRef.current || controller.signal.aborted) return
        const currentSync = syncByScopeRef.current.get(scope)
        if (currentSync) {
          currentSync.requestInFlight = false
          currentSync.compactionRequested = false
        }
        setState((prev) =>
          prev.scope === scope && prev.status === 'loaded' ? prev : { scope, status: 'error' },
        )
      })

    return () => {
      controller.abort()
    }
  }, [path, scope, resyncToken, refreshToken, compactionToken])

  useLiveAlertTransitions((alert) => {
    if (deviceId && alert.deviceId !== deviceId) return
    let sync = syncByScopeRef.current.get(scope)
    if (!sync) {
      sync = {
        watermark: null,
        journal: [],
        requestInFlight: false,
        retainedIds: new Set(),
        compactionRequested: false,
      }
      syncByScopeRef.current.set(scope, sync)
    }
    if (sync.watermark !== null && alert.sequence <= sync.watermark) return
    if (sync.requestInFlight || sync.watermark === null) sync.journal.push(alert)
    sync.retainedIds.add(alert.id)
    if (
      sync.retainedIds.size > MAX_RETAINED_ALERT_IDS &&
      !sync.requestInFlight &&
      !sync.compactionRequested &&
      sync.watermark !== null
    ) {
      // Out-of-order protection requires retaining resolved tombstones until
      // an authoritative watermark covers them. Compact with one event-driven
      // resync instead of imposing a lossy local cap or polling.
      sync.compactionRequested = true
      setCompactionToken((token) => token + 1)
    }
    setState((prev) =>
      prev.scope === scope && prev.status === 'loaded'
        ? { ...prev, store: mergeAlert(prev.store, alert) }
        : prev,
    )
  })

  if (state.scope !== scope) return { status: 'loading' }
  if (state.status !== 'loaded') return { status: state.status }
  return {
    status: 'loaded',
    items: kind === 'active' ? selectActiveAlerts(state.store) : selectRecentAlerts(state.store, limit),
  }
}
