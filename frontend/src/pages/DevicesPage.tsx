import { useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router'
import { Badge, type BadgeVariant } from '../components/Badge'
import { Button } from '../components/Button'
import { EmptyState } from '../components/EmptyState'
import { Select } from '../components/Select'
import { useLiveAlertTransitions } from '../hooks/useLiveAlertTransitions'
import { useReconnectResync } from '../hooks/useReconnectResync'
import { mergeActiveAlert, replayActiveAlerts } from '../lib/alertMerge'
import { fetchJson } from '../lib/api'
import { deriveDeviceStatus, type DeviceStatus } from '../lib/deviceStatus'
import type { AlertEvent, Device } from '../types/domain'

const ALL_FILTER = 'all'

type DevicesState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; devices: Device[] }

type ActiveAlertsState =
  | { status: 'loading' }
  | { status: 'error' }
  | { status: 'loaded'; items: AlertEvent[] }

const STATUS_BADGE_VARIANT: Record<DeviceStatus, BadgeVariant> = {
  ok: 'ok',
  warning: 'warning',
  critical: 'critical',
}

function uniqueSorted(values: string[]): string[] {
  return [...new Set(values)].sort((a, b) => a.localeCompare(b))
}

export function DevicesPage() {
  const [devicesState, setDevicesState] = useState<DevicesState>({ status: 'loading' })
  const [activeAlertsState, setActiveAlertsState] = useState<ActiveAlertsState>({ status: 'loading' })
  const [reloadToken, setReloadToken] = useState(0)
  const [kind, setKind] = useState(ALL_FILTER)
  const [location, setLocation] = useState(ALL_FILTER)
  const [status, setStatus] = useState(ALL_FILTER)
  const resyncToken = useReconnectResync()

  // Buffer for live alert transitions arriving while GET /api/alerts/active
  // is in flight (issue #75 M1): the backend can answer that query before an
  // alert already delivered over the WebSocket was inserted. Replayed onto
  // the snapshot once it resolves; see DeviceDetailPage for the fuller note.
  const activeAlertsBufferRef = useRef<AlertEvent[]>([])
  const activeAlertsInFlightRef = useRef(true)

  useEffect(() => {
    let current = true

    fetchJson<Device[]>('/devices')
      .then((devices) => current && setDevicesState({ status: 'loaded', devices }))
      .catch(() => current && setDevicesState({ status: 'error' }))

    return () => {
      current = false
    }
  }, [reloadToken])

  useEffect(() => {
    let current = true
    activeAlertsBufferRef.current = []
    activeAlertsInFlightRef.current = true

    fetchJson<AlertEvent[]>('/alerts/active')
      .then((items) => {
        if (!current) {
          return
        }
        const replayed = replayActiveAlerts(items, activeAlertsBufferRef.current)
        activeAlertsBufferRef.current = []
        activeAlertsInFlightRef.current = false
        setActiveAlertsState({ status: 'loaded', items: replayed })
      })
      .catch(() => {
        if (!current) {
          return
        }
        // Snapshot-and-clear happens here, not inside the setState updater
        // (see DeviceDetailPage's equivalent catch for why: a setState
        // updater must be pure, and React may invoke it more than once).
        const buffered = activeAlertsBufferRef.current
        activeAlertsBufferRef.current = []
        activeAlertsInFlightRef.current = false
        setActiveAlertsState((prev) =>
          prev.status === 'loaded'
            ? { status: 'loaded', items: replayActiveAlerts(prev.items, buffered) }
            : { status: 'error' },
        )
      })

    return () => {
      current = false
    }
    // resyncToken: after a reconnect, #74 clears its live alert buffer (a
    // transition may have been missed while down) -- re-fetch the
    // authoritative active-alerts snapshot. The device registry itself is
    // not WS-driven, so it deliberately does not refetch here.
  }, [reloadToken, resyncToken])

  useLiveAlertTransitions((alert) => {
    if (activeAlertsInFlightRef.current) {
      activeAlertsBufferRef.current.push(alert)
      return
    }
    setActiveAlertsState((prev) =>
      prev.status !== 'loaded' ? prev : { status: 'loaded', items: mergeActiveAlert(prev.items, alert) },
    )
  })

  const kindOptions = useMemo(
    () => (devicesState.status === 'loaded' ? uniqueSorted(devicesState.devices.map((d) => d.kind)) : []),
    [devicesState],
  )
  const locationOptions = useMemo(
    () =>
      devicesState.status === 'loaded' ? uniqueSorted(devicesState.devices.map((d) => d.location)) : [],
    [devicesState],
  )

  const rows = useMemo(() => {
    if (devicesState.status !== 'loaded' || activeAlertsState.status !== 'loaded') {
      return []
    }
    const activeAlerts = activeAlertsState.items
    return devicesState.devices
      .map((device) => ({
        device,
        status: deriveDeviceStatus(device.deviceId, activeAlerts),
      }))
      .filter(({ device, status: deviceStatus }) => {
        if (kind !== ALL_FILTER && device.kind !== kind) {
          return false
        }
        if (location !== ALL_FILTER && device.location !== location) {
          return false
        }
        if (status !== ALL_FILTER && deviceStatus !== status) {
          return false
        }
        return true
      })
      .sort((a, b) => a.device.name.localeCompare(b.device.name))
  }, [devicesState, activeAlertsState, kind, location, status])

  if (devicesState.status === 'loading' || activeAlertsState.status === 'loading') {
    return <p className="text-sm text-muted">Loading devices…</p>
  }

  if (devicesState.status === 'error' || activeAlertsState.status === 'error') {
    return (
      <EmptyState
        title="Couldn't load devices"
        description="Something went wrong while loading the device registry."
        action={
          <Button
            variant="secondary"
            onClick={() => {
              setDevicesState({ status: 'loading' })
              setActiveAlertsState({ status: 'loading' })
              setReloadToken((t) => t + 1)
            }}
          >
            Retry
          </Button>
        }
      />
    )
  }

  if (devicesState.devices.length === 0) {
    return <EmptyState title="No devices" description="No devices are registered yet." />
  }

  return (
    <div className="flex flex-col gap-md">
      <div className="flex flex-wrap gap-md">
        <Select
          label="Kind"
          value={kind}
          onChange={setKind}
          options={[
            { value: ALL_FILTER, label: 'All kinds' },
            ...kindOptions.map((value) => ({ value, label: value })),
          ]}
        />
        <Select
          label="Location"
          value={location}
          onChange={setLocation}
          options={[
            { value: ALL_FILTER, label: 'All locations' },
            ...locationOptions.map((value) => ({ value, label: value })),
          ]}
        />
        <Select
          label="Status"
          value={status}
          onChange={setStatus}
          options={[
            { value: ALL_FILTER, label: 'All statuses' },
            { value: 'ok', label: 'OK' },
            { value: 'warning', label: 'Warning' },
            { value: 'critical', label: 'Critical' },
          ]}
        />
      </div>

      {rows.length === 0 ? (
        <EmptyState
          title="No matching devices"
          description="No devices match the current filters."
        />
      ) : (
        <ul className="flex flex-col gap-sm">
          {rows.map(({ device, status: deviceStatus }) => (
            <li key={device.deviceId}>
              <Link
                to={`/devices/${device.deviceId}`}
                className="flex items-center justify-between gap-md rounded-md border border-border bg-surface p-md hover:bg-surface-raised"
              >
                <div className="flex flex-col">
                  <span className="text-base text-foreground">{device.name}</span>
                  <span className="text-sm text-muted">{device.location}</span>
                </div>
                <div className="flex items-center gap-md">
                  <span className="text-sm text-muted">{device.kind}</span>
                  <Badge variant={STATUS_BADGE_VARIANT[deviceStatus]}>{deviceStatus}</Badge>
                </div>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
