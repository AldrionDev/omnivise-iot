import { useEffect, useMemo, useState } from 'react'
import { Badge, type BadgeVariant } from '../components/Badge'
import { EmptyState } from '../components/EmptyState'
import { Select } from '../components/Select'
import { useAlertsSnapshot, type AlertSnapshotFilters } from '../hooks/useAlertsSnapshot'
import { useClockTick } from '../hooks/useClockTick'
import { fetchJson } from '../lib/api'
import { formatRelativeTime } from '../lib/relativeTime'
import type { AlertSeverity, AlertState, Device } from '../types/domain'

const ALL_FILTER = 'all'
const CLOCK_TICK_MS = 30_000
const ALERTS_LIMIT = 500

type DevicesState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; devices: Device[] }

const SEVERITY_BADGE_VARIANT: Record<AlertSeverity, BadgeVariant> = {
  warning: 'warning',
  critical: 'critical',
}

function deviceLabel(deviceId: string, devices: Device[]): string {
  return devices.find((d) => d.deviceId === deviceId)?.name ?? deviceId
}

export function AlertsPage() {
  const [devicesState, setDevicesState] = useState<DevicesState>({ status: 'loading' })
  const [stateFilter, setStateFilter] = useState<typeof ALL_FILTER | AlertState>(ALL_FILTER)
  const [severityFilter, setSeverityFilter] = useState<typeof ALL_FILTER | AlertSeverity>(ALL_FILTER)
  const [deviceFilter, setDeviceFilter] = useState(ALL_FILTER)
  const now = useClockTick(CLOCK_TICK_MS)
  const alertFilters: AlertSnapshotFilters = {
    ...(stateFilter === ALL_FILTER ? {} : { state: stateFilter }),
    ...(severityFilter === ALL_FILTER ? {} : { severity: severityFilter }),
    ...(deviceFilter === ALL_FILTER ? {} : { deviceId: deviceFilter }),
  }
  const alertQuery = new URLSearchParams({ limit: String(ALERTS_LIMIT) })
  if (alertFilters.state) alertQuery.set('state', alertFilters.state)
  if (alertFilters.severity) alertQuery.set('severity', alertFilters.severity)
  if (alertFilters.deviceId) alertQuery.set('deviceId', alertFilters.deviceId)
  const alertsState = useAlertsSnapshot(
    `/alerts?${alertQuery.toString()}`,
    'recent',
    ALERTS_LIMIT,
    undefined,
    0,
    alertFilters,
  )

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
  const deviceOptions = useMemo(() => [...devices].sort((a, b) => a.name.localeCompare(b.name)), [devices])

  const rows = useMemo(() => (alertsState.status === 'loaded' ? alertsState.items : []), [alertsState])

  return (
    <div className="flex flex-col gap-md">
      <div className="flex flex-wrap gap-md">
        <Select
          label="State"
          value={stateFilter}
          onChange={(value) => setStateFilter(value as typeof ALL_FILTER | AlertState)}
          options={[
            { value: ALL_FILTER, label: 'All states' },
            { value: 'firing', label: 'Firing' },
            { value: 'resolved', label: 'Resolved' },
          ]}
        />
        <Select
          label="Severity"
          value={severityFilter}
          onChange={(value) => setSeverityFilter(value as typeof ALL_FILTER | AlertSeverity)}
          options={[
            { value: ALL_FILTER, label: 'All severities' },
            { value: 'warning', label: 'Warning' },
            { value: 'critical', label: 'Critical' },
          ]}
        />
        <Select
          label="Device"
          value={deviceFilter}
          onChange={setDeviceFilter}
          options={[
            { value: ALL_FILTER, label: 'All devices' },
            ...deviceOptions.map((device) => ({ value: device.deviceId, label: device.name })),
          ]}
        />
      </div>

      {alertsState.status === 'loading' ? (
        <p className="text-sm text-muted">Loading alerts…</p>
      ) : alertsState.status === 'error' ? (
        <EmptyState title="Couldn't load alerts" description="Something went wrong while loading alerts." />
      ) : rows.length === 0 ? (
        <EmptyState title="No matching alerts" description="No alerts match the current filters." />
      ) : (
        <ul className="flex flex-col gap-xs">
          {rows.map((alert) => (
            <li
              key={alert.id}
              className={`flex items-center justify-between gap-md rounded-md border border-border bg-surface p-sm ${
                alert.state === 'resolved' ? 'opacity-60' : ''
              }`}
            >
              <div className="flex flex-col">
                <span className="text-sm text-foreground">
                  {deviceLabel(alert.deviceId, devices)} · {alert.channel} · {alert.ruleId}
                </span>
                <span className="text-sm text-muted">
                  {alert.state} · {formatRelativeTime(alert.startedAt, now)}
                </span>
              </div>
              <Badge variant={SEVERITY_BADGE_VARIANT[alert.severity]}>{alert.severity}</Badge>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
