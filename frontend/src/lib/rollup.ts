import { deriveDeviceStatus } from './deviceStatus'
import type { AlertEvent, Device } from '../types/domain'

/**
 * Overview roll-up wording (issue #76), distinct from #75's DevicesPage
 * status wording ("warning") -- the underlying derivation is the same
 * {@link deriveDeviceStatus}, only the label differs per page.
 */
export type RollupStatus = 'ok' | 'degraded' | 'critical'

export interface StatusRollup {
  ok: number
  degraded: number
  critical: number
}

const TO_ROLLUP_STATUS: Record<ReturnType<typeof deriveDeviceStatus>, RollupStatus> = {
  ok: 'ok',
  warning: 'degraded',
  critical: 'critical',
}

/** Tallies every device into the Overview roll-up tiles by its derived status. */
export function computeStatusRollup(devices: Device[], activeAlerts: AlertEvent[]): StatusRollup {
  const rollup: StatusRollup = { ok: 0, degraded: 0, critical: 0 }
  for (const device of devices) {
    const status = TO_ROLLUP_STATUS[deriveDeviceStatus(device.deviceId, activeAlerts)]
    rollup[status] += 1
  }
  return rollup
}

const SEVERITY_RANK: Record<AlertEvent['severity'], number> = { critical: 0, warning: 1 }

/**
 * Top-N active alerts for the Overview widget: critical before warning,
 * newest-first within the same severity. `activeAlerts` is expected to
 * already be state=firing (does not filter by state itself).
 */
export function topActiveAlerts(activeAlerts: AlertEvent[], limit: number): AlertEvent[] {
  return [...activeAlerts]
    .sort((a, b) => {
      const severityDiff = SEVERITY_RANK[a.severity] - SEVERITY_RANK[b.severity]
      return severityDiff !== 0 ? severityDiff : b.startedAt.localeCompare(a.startedAt)
    })
    .slice(0, limit)
}
