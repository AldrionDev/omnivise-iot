import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router'
import { Badge, type BadgeVariant } from '../components/Badge'
import { Card } from '../components/Card'
import { EmptyState } from '../components/EmptyState'
import { Sparkline, type SparklineStatus } from '../components/Sparkline'
import { useAlertsSnapshot } from '../hooks/useAlertsSnapshot'
import { useClockTick } from '../hooks/useClockTick'
import { useLiveStreamContext } from '../hooks/LiveStreamContext'
import { fetchJson } from '../lib/api'
import { deriveDeviceStatus, type DeviceStatus } from '../lib/deviceStatus'
import {
  aggregateLatestValue,
  devicesWithChannel,
  maxOf,
  mergeHistorySeries,
  type SparklinePoint,
} from '../lib/metrics'
import { resolveHistoryWindow } from '../lib/range'
import { formatRelativeTime } from '../lib/relativeTime'
import { computeStatusRollup, topActiveAlerts, type RollupStatus } from '../lib/rollup'
import type { AlertEvent, Device, SensorHistory } from '../types/domain'

const TOP_ALERTS_LIMIT = 5
const SPARKLINE_RANGE = '15m' as const
const CLOCK_TICK_MS = 30_000

// Approved topology (mongo-init.js): exact seeded channel names, not guessed.
const EXHAUST_TEMP_CHANNEL = 'exhaust_temp'
const POWER_DRAW_CHANNEL = 'power_draw'
const PDU_DEVICE_ID = 'pdu-a1'
const UPS_DEVICE_ID = 'ups-1'
const BATTERY_PCT_CHANNEL = 'battery_pct'

type DevicesState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; devices: Device[] }

interface HeadlineMetricConfig {
  key: string
  label: string
  unit: string
  deviceIds: string[]
  channel: string
  combine: (values: number[]) => number
}

interface MetricHistoryState {
  status: SparklineStatus
  points: SparklinePoint[]
}

const STATUS_BADGE_VARIANT: Record<DeviceStatus, BadgeVariant> = {
  ok: 'ok',
  warning: 'warning',
  critical: 'critical',
}

const ROLLUP_TONE_CLASS: Record<RollupStatus, string> = {
  ok: 'text-status-ok',
  degraded: 'text-status-warning',
  critical: 'text-status-critical',
}

const SEVERITY_BADGE_VARIANT: Record<AlertEvent['severity'], BadgeVariant> = {
  warning: 'warning',
  critical: 'critical',
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function formatMetricValue(value: number | null, unit: string): string {
  return value === null ? 'No live value' : `${value} ${unit}`
}

export function OverviewPage() {
  const { latestReadings } = useLiveStreamContext()
  const now = useClockTick(CLOCK_TICK_MS)

  const [devicesState, setDevicesState] = useState<DevicesState>({ status: 'loading' })
  // Overview reacts live to active alerts, but the device registry itself is
  // not WS-driven, so (matching DevicesPage) it is fetched once and never
  // refetched on reconnect.
  const activeAlertsState = useAlertsSnapshot('/alerts/active', 'active')

  useEffect(() => {
    let current = true

    fetchJson<Device[]>('/devices')
      .then((devices) => current && setDevicesState({ status: 'loaded', devices }))
      .catch(() => current && setDevicesState({ status: 'error' }))

    return () => {
      current = false
    }
  }, [])

  const devices = useMemo(() => (devicesState.status === 'loaded' ? devicesState.devices : []), [devicesState])

  const exhaustDeviceIds = useMemo(
    () => devicesWithChannel(devices, EXHAUST_TEMP_CHANNEL).map((d) => d.deviceId),
    [devices],
  )
  // PDU power is the room-level aggregate. Rack power readings are deliberately
  // excluded so the headline does not count the same load twice.
  const powerDeviceIds = useMemo(
    () => devices.some((device) => device.deviceId === PDU_DEVICE_ID && device.channels.some((c) => c.channel === POWER_DRAW_CHANNEL))
      ? [PDU_DEVICE_ID]
      : [],
    [devices],
  )

  const metricConfigs: HeadlineMetricConfig[] = useMemo(
    () => [
      {
        key: 'exhaust',
        label: 'Max rack exhaust temperature',
        unit: '°C',
        deviceIds: exhaustDeviceIds,
        channel: EXHAUST_TEMP_CHANNEL,
        combine: maxOf,
      },
      {
        key: 'power',
        label: 'Total power draw',
        unit: 'W',
        deviceIds: powerDeviceIds,
        channel: POWER_DRAW_CHANNEL,
        combine: (values) => values[0],
      },
      {
        key: 'battery',
        label: 'UPS battery',
        unit: '%',
        deviceIds: [UPS_DEVICE_ID],
        channel: BATTERY_PCT_CHANNEL,
        combine: (values) => values[0],
      },
    ],
    [exhaustDeviceIds, powerDeviceIds],
  )

  const [metricHistory, setMetricHistory] = useState<Record<string, MetricHistoryState>>({})

  useEffect(() => {
    if (devicesState.status !== 'loaded') {
      return
    }
    let current = true
    const controller = new AbortController()
    // One shared `to` for every sparkline request in this refresh.
    const window = resolveHistoryWindow(SPARKLINE_RANGE, new Date())

    for (const metric of metricConfigs) {
      Promise.all(
        metric.deviceIds.map((deviceId) => {
          const params = new URLSearchParams({
            deviceId,
            channel: metric.channel,
            from: window.from,
            to: window.to,
            bucket: window.bucket,
          })
          return fetchJson<SensorHistory>(`/sensors/history?${params}`, { signal: controller.signal })
        }),
      )
        .then((results) => {
          if (!current) {
            return
          }
          const points = mergeHistorySeries(
            results.map((r) => r.points),
            metric.combine,
          )
          setMetricHistory((prev) => ({ ...prev, [metric.key]: { status: 'ready', points } }))
        })
        .catch((error: unknown) => {
          if (!current || isAbortError(error)) {
            return
          }
          setMetricHistory((prev) => ({ ...prev, [metric.key]: { status: 'error', points: [] } }))
        })
    }

    return () => {
      current = false
      controller.abort()
    }
  }, [devicesState.status, metricConfigs])

  const rollup =
    devicesState.status === 'loaded' && activeAlertsState.status === 'loaded'
      ? computeStatusRollup(devicesState.devices, activeAlertsState.items)
      : null

  const topAlerts = activeAlertsState.status === 'loaded' ? topActiveAlerts(activeAlertsState.items, TOP_ALERTS_LIMIT) : []

  if (devicesState.status === 'loading' || activeAlertsState.status === 'loading') {
    return <p className="text-sm text-muted">Loading overview…</p>
  }

  if (devicesState.status === 'error' || activeAlertsState.status === 'error') {
    return (
      <EmptyState
        title="Couldn't load overview"
        description="Something went wrong while loading the fleet overview."
      />
    )
  }

  return (
    <div className="flex min-w-0 flex-col gap-lg">
      <section aria-label="Status roll-up" className="grid grid-cols-1 gap-md sm:grid-cols-3">
        {(['ok', 'degraded', 'critical'] as const).map((status) => (
          <Card key={status} className="flex flex-col gap-xs">
            <span className="text-sm text-muted capitalize">{status}</span>
            <span className={`text-lg ${ROLLUP_TONE_CLASS[status]}`}>{rollup ? rollup[status] : 0}</span>
          </Card>
        ))}
      </section>

      <section aria-label="Headline metrics" className="grid grid-cols-1 gap-md md:grid-cols-3">
        {metricConfigs.map((metric) => {
          const currentValue = aggregateLatestValue(metric.deviceIds, metric.channel, latestReadings, metric.combine)
          const history = metricHistory[metric.key] ?? { status: 'loading' as const, points: [] }
          return (
            <Card key={metric.key} className="flex flex-col gap-sm">
              <span className="break-words text-sm text-muted">{metric.label}</span>
              <span className="break-words text-lg text-foreground">{formatMetricValue(currentValue, metric.unit)}</span>
              <Sparkline status={history.status} points={history.points} />
            </Card>
          )
        })}
      </section>

      <section aria-label="Active alerts" className="flex flex-col gap-sm">
        <div className="flex items-center justify-between">
          <h2 className="text-base text-foreground">Active alerts</h2>
          <Link to="/alerts" className="text-sm text-accent">
            View all
          </Link>
        </div>
        {topAlerts.length === 0 ? (
          <EmptyState title="No active alerts" description="Nothing is currently firing." />
        ) : (
          <ul className="flex flex-col gap-xs">
            {topAlerts.map((alert) => (
              <li
                key={alert.id}
                className="flex min-w-0 items-center justify-between gap-md rounded-md border border-border bg-surface p-sm"
              >
                <div className="min-w-0 flex flex-1 flex-col break-words">
                  <span className="text-sm text-foreground">
                    {alert.deviceId} · {alert.channel}
                  </span>
                  <span className="text-sm text-muted">{formatRelativeTime(alert.startedAt, now)}</span>
                </div>
                <Badge variant={SEVERITY_BADGE_VARIANT[alert.severity]}>{alert.severity}</Badge>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-label="Devices" className="flex flex-col gap-sm">
        <h2 className="text-base text-foreground">Devices</h2>
        {devices.length === 0 ? (
          <EmptyState title="No devices" description="No devices are registered yet." />
        ) : (
          <div className="grid grid-cols-1 gap-md sm:grid-cols-2 lg:grid-cols-3">
            {devices.map((device) => {
              const status =
                activeAlertsState.status === 'loaded'
                  ? deriveDeviceStatus(device.deviceId, activeAlertsState.items)
                  : 'ok'
              return (
                <Link key={device.deviceId} to={`/devices/${device.deviceId}`}>
                  <Card className="flex flex-col gap-xs hover:bg-surface-raised">
                      <div className="flex min-w-0 items-center justify-between gap-sm">
                      <span className="min-w-0 break-words text-base text-foreground">{device.name}</span>
                      <Badge variant={STATUS_BADGE_VARIANT[status]}>{status}</Badge>
                    </div>
                    <span className="break-words text-sm text-muted">{device.location}</span>
                    <span className="text-sm text-muted">{device.kind}</span>
                  </Card>
                </Link>
              )
            })}
          </div>
        )}
      </section>
    </div>
  )
}
