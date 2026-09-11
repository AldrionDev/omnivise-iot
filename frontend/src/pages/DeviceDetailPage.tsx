import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { useParams } from 'react-router'
import { Badge, type BadgeVariant } from '../components/Badge'
import { EmptyState } from '../components/EmptyState'
import { Button } from '../components/Button'
import { TimeSeriesChart, type TimeSeriesChartStatus } from '../components/TimeSeriesChart'
import { useAlertsSnapshot } from '../hooks/useAlertsSnapshot'
import { useLiveStreamContext } from '../hooks/LiveStreamContext'
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

  const [deviceState, setDeviceState] = useState<DeviceState>({ status: 'loading' })
  const encodedDeviceId = deviceId ? encodeURIComponent(deviceId) : ''
  const activeAlerts = useAlertsSnapshot(
    `/alerts/active?deviceId=${encodedDeviceId}`,
    'active',
    20,
    deviceId,
  )
  const [rules, setRules] = useState<ListState<AlertRule>>({ status: 'loading' })
  const recentAlerts = useAlertsSnapshot(
    `/alerts?deviceId=${encodedDeviceId}&limit=${RECENT_ALERTS_LIMIT}`,
    'recent',
    RECENT_ALERTS_LIMIT,
    deviceId,
  )
  const [range, setRange] = useState<HistoryRange>(DEFAULT_RANGE)
  const [channelHistory, setChannelHistory] = useState<Record<string, ChannelHistoryState>>({})

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

    fetchJson<AlertRule[]>(`/alerts/rules?deviceId=${encodeURIComponent(deviceId)}`)
      .then((items) => current && setRules({ status: 'loaded', items }))
      .catch(() => current && setRules({ status: 'error' }))

    return () => {
      current = false
    }
  }, [deviceId])

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
