import { describe, expect, it } from 'vitest'
import { deriveDeviceStatus } from './deviceStatus'
import type { AlertEvent } from '../types/domain'

function activeAlert(overrides: Partial<AlertEvent>): AlertEvent {
  return {
    id: 'a1',
    ruleId: 'r1',
    deviceId: 'rack-a1',
    channel: 'intake_temp',
    severity: 'warning',
    state: 'firing',
    triggeredValue: 31,
    lastValue: 31,
    startedAt: '2026-09-11T08:00:00Z',
    resolvedAt: null,
    ...overrides,
  }
}

describe('deriveDeviceStatus', () => {
  it('is ok when there are no active alerts for the device', () => {
    expect(deriveDeviceStatus('rack-a1', [])).toBe('ok')
  })

  it('is warning when the device has an active warning alert', () => {
    const alerts = [activeAlert({ deviceId: 'rack-a1', severity: 'warning' })]
    expect(deriveDeviceStatus('rack-a1', alerts)).toBe('warning')
  })

  it('is critical when the device has an active critical alert', () => {
    const alerts = [activeAlert({ deviceId: 'rack-a1', severity: 'critical' })]
    expect(deriveDeviceStatus('rack-a1', alerts)).toBe('critical')
  })

  it('prefers critical over warning when both are present for the device', () => {
    const alerts = [
      activeAlert({ deviceId: 'rack-a1', severity: 'warning' }),
      activeAlert({ deviceId: 'rack-a1', severity: 'critical' }),
    ]
    expect(deriveDeviceStatus('rack-a1', alerts)).toBe('critical')
  })

  it('ignores alerts belonging to other devices', () => {
    const alerts = [activeAlert({ deviceId: 'ups-1', severity: 'critical' })]
    expect(deriveDeviceStatus('rack-a1', alerts)).toBe('ok')
  })
})
