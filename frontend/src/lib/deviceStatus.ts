import type { AlertEvent } from '../types/domain'

export type DeviceStatus = 'ok' | 'warning' | 'critical'

/**
 * critical if the device has an active critical alert, else warning if it has
 * an active warning alert, else ok. `activeAlerts` is expected to already be
 * state=firing (GET /api/alerts/active) -- this does not filter by state.
 */
export function deriveDeviceStatus(deviceId: string, activeAlerts: AlertEvent[]): DeviceStatus {
  let hasWarning = false
  for (const alert of activeAlerts) {
    if (alert.deviceId !== deviceId) {
      continue
    }
    if (alert.severity === 'critical') {
      return 'critical'
    }
    if (alert.severity === 'warning') {
      hasWarning = true
    }
  }
  return hasWarning ? 'warning' : 'ok'
}
