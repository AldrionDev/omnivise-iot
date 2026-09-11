import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useParams } from 'react-router'
import { Badge, type BadgeVariant } from '../components/Badge'
import { EmptyState } from '../components/EmptyState'
import { Button } from '../components/Button'
import { TimeSeriesChart, type TimeSeriesChartStatus } from '../components/TimeSeriesChart'
import { useLiveAlertTransitions } from '../hooks/useLiveAlertTransitions'
import { useLiveStreamContext } from '../hooks/LiveStreamContext'
import { useReconnectResync } from '../hooks/useReconnectResync'
import {
  mergeActiveAlert,
  mergeRecentAlert,
  replayActiveAlerts,
  replayRecentAlerts,
} from '../lib/alertMerge'
import { ApiError, fetchJson } from '../lib/api'
import { deriveDeviceStatus, type DeviceStatus } from '../lib/deviceStatus'
import { HISTORY_RANGES, resolveHistoryWindow, type HistoryRange } from '../lib/range'
import type { AlertEvent, AlertRule, Device, HistoryPoint, Reading, SensorHistory } from '../types/domain'

const NON_NUMERIC_UNIT = 'state'
const RECENT_ALERTS_LIMIT = 20
const DEFAULT_RANGE: HistoryRange = '1h'

type DeviceState =
  | { status: 'loading' }
  | { status: 'not-found' }
  | { status: 'error' }
  | { status: 'loaded'; device: Device }

type ListState<T> =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; items: T[] }

interface ChannelHistoryState {
  status: TimeSeriesChartStatus
  points: HistoryPoint[]
}

const STATUS_BADGE_VARIANT: Record<DeviceStatus, BadgeVariant> = {
  ok: 'ok',
  warning: 'warning',
  critical: 'critical',
}

const SEVERITY_BADGE_VARIANT: Record<AlertEvent['severity'], BadgeVariant> = {
  warning: 'warning',
  critical: 'critical',
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

/** Live values come only from LiveStreamContext -- never derived from history (issue #75). */
function formatLiveReading(reading: Reading | undefined, unit: string): string {
  if (!reading) {
    return 'No live value'
  }
  return typeof reading.value === 'number' ? `${reading.value} ${unit}` : reading.value
}

interface ChannelCardProps {
  channel: string
  liveValue: string
  children: ReactNode
}

function ChannelCard({ channel, liveValue, children }: ChannelCardProps) {
  return (
    <div className="flex flex-col gap-sm rounded-md border border-border bg-surface p-md">
      <div className="flex items-center justify-between">
        <span className="text-base text-foreground">{channel}</span>
        <span className="text-sm text-muted">{liveValue}</span>
      </div>
      {children}
    </div>
  )
}

export function DeviceDetailPage() {
  const { deviceId } = useParams<{ deviceId: string }>()
  const { latestReadings } = useLiveStreamContext()
  const resyncToken = useReconnectResync()

  const [deviceState, setDeviceState] = useState<DeviceState>({ status: 'loading' })
  const [activeAlerts, setActiveAlerts] = useState<ListState<AlertEvent>>({ status: 'loading' })
  const [rules, setRules] = useState<ListState<AlertRule>>({ status: 'loading' })
  const [recentAlerts, setRecentAlerts] = useState<ListState<AlertEvent>>({ status: 'loading' })
  const [range, setRange] = useState<HistoryRange>(DEFAULT_RANGE)
  const [channelHistory, setChannelHistory] = useState<Record<string, ChannelHistoryState>>({})

  // Buffers for live alert transitions that arrive while the corresponding
  // REST snapshot fetch is in flight (issue #75 M1): a snapshot query can be
  // answered by the backend before an alert that already reached us over the
  // WebSocket was inserted, so applying that snapshot naively can lose or
  // overwrite the live update. While *Ref.current is true, a transition for
  // this device is queued here instead of merged into visible state; once
  // the fetch resolves, the queue is replayed on top of the snapshot (in
  // arrival order) and cleared. Reset at the top of each fetch effect run so
  // a stale buffer never survives into a new device or a new resync.
  const activeAlertsBufferRef = useRef<AlertEvent[]>([])
  const activeAlertsInFlightRef = useRef(true)
  const recentAlertsBufferRef = useRef<AlertEvent[]>([])
  const recentAlertsInFlightRef = useRef(true)

  useEffect(() => {
    if (!deviceId) {
      return
    }
    let current = true

    fetchJson<Device>(`/devices/${encodeURIComponent(deviceId)}`)
      .then((device) => {
        if (current) {
          setDeviceState({ status: 'loaded', device })
        }
      })
      .catch((error: unknown) => {
        if (!current) {
          return
        }
        setDeviceState({ status: error instanceof ApiError && error.status === 404 ? 'not-found' : 'error' })
      })

    return () => {
      current = false
    }
  }, [deviceId])

  useEffect(() => {
    if (!deviceId) {
      return
    }
    let current = true
    activeAlertsBufferRef.current = []
    activeAlertsInFlightRef.current = true

    fetchJson<AlertEvent[]>(`/alerts/active?deviceId=${encodeURIComponent(deviceId)}`)
      .then((items) => {
        if (!current) {
          return
        }
        const replayed = replayActiveAlerts(items, activeAlertsBufferRef.current)
        activeAlertsBufferRef.current = []
        activeAlertsInFlightRef.current = false
        setActiveAlerts({ status: 'loaded', items: replayed })
      })
      .catch(() => {
        if (!current) {
          return
        }
        // Snapshot-and-clear happens here, in the (already request-current-
        // guarded) catch body -- NOT inside the setState updater below. A
        // setState updater must be pure (React may invoke it more than once,
        // e.g. under StrictMode, keeping only the last result); reading and
        // clearing a ref from inside it would make the first invocation's
        // clear invisible to -- and unrecoverable by -- the second, silently
        // dropping the buffered transitions (issue #75 review finding B1).
        const buffered = activeAlertsBufferRef.current
        activeAlertsBufferRef.current = []
        activeAlertsInFlightRef.current = false
        setActiveAlerts((prev) =>
          // A refetch (resync) failing while we already have good data must
          // not blank the badge -- keep serving the stale-but-live-patched
          // state. Only a genuine first-load failure (no prior snapshot to
          // build on) falls back to the error state; a later successful
          // fetch/resync gets a fresh authoritative query from the backend
          // regardless, so nothing buffered here is lost forever.
          prev.status === 'loaded'
            ? { status: 'loaded', items: replayActiveAlerts(prev.items, buffered) }
            : { status: 'error' },
        )
      })

    return () => {
      current = false
    }
    // resyncToken: re-fetch the authoritative snapshot after a reconnect --
    // #74 clears its live alert buffer on every disconnect, so transitions
    // missed while down must come from REST, not be assumed from the buffer.
  }, [deviceId, resyncToken])

  useEffect(() => {
    if (!deviceId) {
      return
    }
    let current = true

    fetchJson<AlertRule[]>(`/alerts/rules?deviceId=${encodeURIComponent(deviceId)}`)
      .then((items) => current && setRules({ status: 'loaded', items }))
      .catch(() => current && setRules({ status: 'error' }))

    return () => {
      current = false
    }
  }, [deviceId])

  useEffect(() => {
    if (!deviceId) {
      return
    }
    let current = true
    recentAlertsBufferRef.current = []
    recentAlertsInFlightRef.current = true

    fetchJson<AlertEvent[]>(
      `/alerts?deviceId=${encodeURIComponent(deviceId)}&limit=${RECENT_ALERTS_LIMIT}`,
    )
      .then((items) => {
        if (!current) {
          return
        }
        const replayed = replayRecentAlerts(items, recentAlertsBufferRef.current, RECENT_ALERTS_LIMIT)
        recentAlertsBufferRef.current = []
        recentAlertsInFlightRef.current = false
        setRecentAlerts({ status: 'loaded', items: replayed })
      })
      .catch(() => {
        if (!current) {
          return
        }
        // See the activeAlerts catch above: snapshot-and-clear must happen
        // here, not inside the setState updater, so the updater stays pure.
        const buffered = recentAlertsBufferRef.current
        recentAlertsBufferRef.current = []
        recentAlertsInFlightRef.current = false
        setRecentAlerts((prev) =>
          prev.status === 'loaded'
            ? { status: 'loaded', items: replayRecentAlerts(prev.items, buffered, RECENT_ALERTS_LIMIT) }
            : { status: 'error' },
        )
      })

    return () => {
      current = false
    }
    // resyncToken: see the activeAlerts effect above for why.
  }, [deviceId, resyncToken])

  useLiveAlertTransitions((alert) => {
    if (alert.deviceId !== deviceId) {
      return
    }
    if (activeAlertsInFlightRef.current) {
      activeAlertsBufferRef.current.push(alert)
    } else {
      setActiveAlerts((prev) =>
        prev.status !== 'loaded' ? prev : { status: 'loaded', items: mergeActiveAlert(prev.items, alert) },
      )
    }
    if (recentAlertsInFlightRef.current) {
      recentAlertsBufferRef.current.push(alert)
    } else {
      setRecentAlerts((prev) =>
        prev.status !== 'loaded' ? prev : { status: 'loaded', items: mergeRecentAlert(prev.items, alert) },
      )
    }
  })

  const numericChannels = useMemo(
    () =>
      deviceState.status === 'loaded'
        ? deviceState.device.channels.filter((c) => c.unit !== NON_NUMERIC_UNIT)
        : [],
    [deviceState],
  )
  const nonNumericChannels = useMemo(
    () =>
      deviceState.status === 'loaded'
        ? deviceState.device.channels.filter((c) => c.unit === NON_NUMERIC_UNIT)
        : [],
    [deviceState],
  )

  useEffect(() => {
    if (!deviceId || numericChannels.length === 0) {
      return
    }
    let current = true
    const controller = new AbortController()
    const window = resolveHistoryWindow(range, new Date())

    for (const channel of numericChannels) {
      const params = new URLSearchParams({
        deviceId,
        channel: channel.channel,
        from: window.from,
        to: window.to,
        bucket: window.bucket,
      })

      fetchJson<SensorHistory>(`/sensors/history?${params}`, { signal: controller.signal })
        .then((data) => {
          if (!current) {
            return
          }
          setChannelHistory((prev) => ({
            ...prev,
            [channel.channel]: { status: 'ready', points: data.points },
          }))
        })
        .catch((error: unknown) => {
          if (!current || isAbortError(error)) {
            return
          }
          setChannelHistory((prev) => ({
            ...prev,
            [channel.channel]: { status: 'error', points: [] },
          }))
        })
    }

    return () => {
      current = false
      controller.abort()
    }
  }, [deviceId, numericChannels, range])

  if (deviceState.status === 'loading') {
    return <p className="text-sm text-muted">Loading device…</p>
  }

  if (deviceState.status === 'not-found') {
    return (
      <EmptyState title="Device not found" description={`No device with id "${deviceId}".`} />
    )
  }

  if (deviceState.status === 'error') {
    return (
      <EmptyState
        title="Couldn't load device"
        description="Something went wrong while loading this device."
      />
    )
  }

  const { device } = deviceState
  const status =
    activeAlerts.status === 'loaded' ? deriveDeviceStatus(device.deviceId, activeAlerts.items) : null

  return (
    <div className="flex flex-col gap-lg">
      <header className="flex flex-wrap items-center justify-between gap-md">
        <div className="flex flex-col">
          <h1 className="text-lg text-foreground">{device.name}</h1>
          <span className="flex gap-xs text-sm text-muted">
            <span>{device.kind}</span>
            <span aria-hidden="true">·</span>
            <span>{device.location}</span>
          </span>
        </div>
        {status && <Badge variant={STATUS_BADGE_VARIANT[status]}>{status}</Badge>}
      </header>

      <div className="flex gap-xs" role="group" aria-label="Range">
        {HISTORY_RANGES.map((r) => (
          <Button
            key={r}
            size="sm"
            variant={r === range ? 'secondary' : 'ghost'}
            aria-pressed={r === range}
            onClick={() => setRange(r)}
          >
            {r}
          </Button>
        ))}
      </div>

      <div className="grid grid-cols-1 gap-md md:grid-cols-2">
        {numericChannels.map((channel) => (
          <ChannelCard
            key={channel.channel}
            channel={channel.channel}
            liveValue={formatLiveReading(latestReadings[`${device.deviceId}::${channel.channel}`], channel.unit)}
          >
            <TimeSeriesChart
              status={channelHistory[channel.channel]?.status ?? 'loading'}
              unit={channel.unit}
              points={channelHistory[channel.channel]?.points ?? []}
            />
          </ChannelCard>
        ))}

        {nonNumericChannels.map((channel) => (
          <ChannelCard
            key={channel.channel}
            channel={channel.channel}
            liveValue={formatLiveReading(latestReadings[`${device.deviceId}::${channel.channel}`], channel.unit)}
          >
            <p className="text-sm text-muted">History chart unavailable for non-numeric channel.</p>
          </ChannelCard>
        ))}
      </div>

      <section className="flex flex-col gap-sm">
        <h2 className="text-base text-foreground">Alert rules</h2>
        {rules.status === 'loading' && <p className="text-sm text-muted">Loading rules…</p>}
        {rules.status === 'error' && (
          <p className="text-sm text-status-critical">Couldn't load alert rules.</p>
        )}
        {rules.status === 'loaded' && rules.items.length === 0 && (
          <p className="text-sm text-muted">No alert rules configured for this device.</p>
        )}
        {rules.status === 'loaded' && rules.items.length > 0 && (
          <ul className="flex flex-col gap-xs">
            {rules.items.map((rule) => (
              <li
                key={rule.ruleId}
                className="flex items-center justify-between gap-md rounded-md border border-border bg-surface p-sm"
              >
                <span className="text-sm text-foreground">
                  {rule.ruleId} · {rule.match.channel} {rule.operator} {rule.threshold}
                </span>
                <Badge variant={SEVERITY_BADGE_VARIANT[rule.severity]}>{rule.severity}</Badge>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="flex flex-col gap-sm">
        <h2 className="text-base text-foreground">Recent alerts</h2>
        {recentAlerts.status === 'loading' && <p className="text-sm text-muted">Loading alerts…</p>}
        {recentAlerts.status === 'error' && (
          <p className="text-sm text-status-critical">Couldn't load recent alerts.</p>
        )}
        {recentAlerts.status === 'loaded' && recentAlerts.items.length === 0 && (
          <p className="text-sm text-muted">No recent alerts for this device.</p>
        )}
        {recentAlerts.status === 'loaded' && recentAlerts.items.length > 0 && (
          <ul className="flex flex-col gap-xs">
            {recentAlerts.items.map((alert) => (
              <li
                key={alert.id}
                className="flex items-center justify-between gap-md rounded-md border border-border bg-surface p-sm"
              >
                <div className="flex flex-col">
                  <span className="text-sm text-foreground">
                    {alert.channel} · {alert.state}
                  </span>
                  <span className="text-sm text-muted">
                    {new Date(alert.startedAt).toLocaleString()}
                  </span>
                </div>
                <Badge variant={SEVERITY_BADGE_VARIANT[alert.severity]}>{alert.severity}</Badge>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  )
}
