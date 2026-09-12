import { describe, expect, it } from 'vitest'
import { computeStatusRollup, topActiveAlerts } from './rollup'
import type { AlertEvent, Device } from '../types/domain'

function device(overrides: Partial<Device>): Device {
  return {
    deviceId: 'rack-a1',
    name: 'Rack A1',
    kind: 'rack',
    location: 'Server Room / Rack A1',
    channels: [],
    ...overrides,
  }
}

function alert(overrides: Partial<AlertEvent>): AlertEvent {
  return {
    sequence: overrides.state === 'resolved' ? 2 : 1,
    id: 'a1',
    ruleId: 'r1',
    deviceId: 'rack-a1',
    channel: 'exhaust_temp',
    severity: 'warning',
    state: 'firing',
    triggeredValue: 31,
    lastValue: 31,
    startedAt: '2026-09-11T08:00:00Z',
    resolvedAt: null,
    ...overrides,
  }
}

describe('computeStatusRollup', () => {
  it('counts every device as ok when there are no active alerts', () => {
    const devices = [device({ deviceId: 'rack-a1' }), device({ deviceId: 'rack-a2' })]
    expect(computeStatusRollup(devices, [])).toEqual({ ok: 2, degraded: 0, critical: 0 })
  })

  it('maps a device with an active warning alert to degraded, not "warning"', () => {
    const devices = [device({ deviceId: 'rack-a1' })]
    const alerts = [alert({ deviceId: 'rack-a1', severity: 'warning' })]
    expect(computeStatusRollup(devices, alerts)).toEqual({ ok: 0, degraded: 1, critical: 0 })
  })

  it('maps a device with an active critical alert to critical', () => {
    const devices = [device({ deviceId: 'rack-a1' })]
    const alerts = [alert({ deviceId: 'rack-a1', severity: 'critical' })]
    expect(computeStatusRollup(devices, alerts)).toEqual({ ok: 0, degraded: 0, critical: 1 })
  })

  it('gives critical precedence over degraded when a device has both severities active', () => {
    const devices = [device({ deviceId: 'rack-a1' })]
    const alerts = [
      alert({ id: 'w1', deviceId: 'rack-a1', severity: 'warning' }),
      alert({ id: 'c1', deviceId: 'rack-a1', severity: 'critical' }),
    ]
    expect(computeStatusRollup(devices, alerts)).toEqual({ ok: 0, degraded: 0, critical: 1 })
  })

  it('tallies a fleet with a mix of statuses independently', () => {
    const devices = [
      device({ deviceId: 'rack-a1' }),
      device({ deviceId: 'rack-a2' }),
      device({ deviceId: 'ups-1', kind: 'ups' }),
    ]
    const alerts = [
      alert({ deviceId: 'rack-a1', severity: 'warning' }),
      alert({ deviceId: 'ups-1', severity: 'critical' }),
    ]
    expect(computeStatusRollup(devices, alerts)).toEqual({ ok: 1, degraded: 1, critical: 1 })
  })

  it('returns all zeros for an empty fleet', () => {
    expect(computeStatusRollup([], [])).toEqual({ ok: 0, degraded: 0, critical: 0 })
  })
})

describe('topActiveAlerts', () => {
  it('orders critical before warning regardless of recency', () => {
    const alerts = [
      alert({ id: 'w1', severity: 'warning', startedAt: '2026-09-11T09:00:00Z' }),
      alert({ id: 'c1', severity: 'critical', startedAt: '2026-09-11T08:00:00Z' }),
    ]
    expect(topActiveAlerts(alerts, 5).map((a) => a.id)).toEqual(['c1', 'w1'])
  })

  it('orders newest first within the same severity', () => {
    const alerts = [
      alert({ id: 'old', severity: 'critical', startedAt: '2026-09-11T08:00:00Z' }),
      alert({ id: 'new', severity: 'critical', startedAt: '2026-09-11T09:00:00Z' }),
    ]
    expect(topActiveAlerts(alerts, 5).map((a) => a.id)).toEqual(['new', 'old'])
  })

  it('applies severity first, then recency, across a mixed set', () => {
    const alerts = [
      alert({ id: 'w-old', severity: 'warning', startedAt: '2026-09-11T07:00:00Z' }),
      alert({ id: 'c-old', severity: 'critical', startedAt: '2026-09-11T06:00:00Z' }),
      alert({ id: 'w-new', severity: 'warning', startedAt: '2026-09-11T09:00:00Z' }),
      alert({ id: 'c-new', severity: 'critical', startedAt: '2026-09-11T08:00:00Z' }),
    ]
    expect(topActiveAlerts(alerts, 10).map((a) => a.id)).toEqual(['c-new', 'c-old', 'w-new', 'w-old'])
  })

  it('truncates to the given limit after sorting', () => {
    const alerts = [
      alert({ id: 'c1', severity: 'critical', startedAt: '2026-09-11T08:00:00Z' }),
      alert({ id: 'c2', severity: 'critical', startedAt: '2026-09-11T09:00:00Z' }),
      alert({ id: 'w1', severity: 'warning', startedAt: '2026-09-11T09:30:00Z' }),
    ]
    expect(topActiveAlerts(alerts, 2).map((a) => a.id)).toEqual(['c2', 'c1'])
  })

  it('does not mutate the input array', () => {
    const alerts = [
      alert({ id: 'w1', severity: 'warning', startedAt: '2026-09-11T08:00:00Z' }),
      alert({ id: 'c1', severity: 'critical', startedAt: '2026-09-11T09:00:00Z' }),
    ]
    const copy = [...alerts]
    topActiveAlerts(alerts, 5)
    expect(alerts).toEqual(copy)
  })

  it('returns an empty array when there are no active alerts', () => {
    expect(topActiveAlerts([], 5)).toEqual([])
  })
})
