import { describe, expect, it } from 'vitest'
import { createAlertStore, mergeAlert, replayAlerts, selectActiveAlerts, selectRecentAlerts } from './alertMerge'
import type { AlertEvent } from '../types/domain'

function alert(sequence: number, overrides: Partial<AlertEvent> = {}): AlertEvent {
  return {
    sequence,
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

describe('sequence-aware alert merge', () => {
  it('accepts only a higher sequence for the same id', () => {
    const resolved = alert(3, { state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })
    const store = createAlertStore([resolved])
    expect(mergeAlert(store, alert(2))).toBe(store)
    expect(selectRecentAlerts(store, 20)).toEqual([resolved])
  })

  it('keeps a resolved tombstone out of active rows and blocks resurrection', () => {
    const resolved = alert(4, { state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })
    const store = mergeAlert(createAlertStore([resolved]), alert(3))
    expect(selectActiveAlerts(store)).toEqual([])
  })

  it('reduces firing and resolved transitions for one id to one resolved row', () => {
    const firing = alert(1)
    const resolved = alert(2, { state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })
    const store = replayAlerts([], [resolved, firing], 0)
    expect(selectRecentAlerts(store, 20)).toEqual([resolved])
  })

  it('replays only events above the watermark in sequence order', () => {
    const snapshot = alert(5, { state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })
    const store = replayAlerts(
      [snapshot],
      [
        alert(4),
        alert(7, { id: 'a2', startedAt: '2026-09-11T08:02:00Z' }),
        alert(6, { id: 'a3', startedAt: '2026-09-11T08:01:00Z' }),
      ],
      5,
    )
    expect(selectRecentAlerts(store, 20).map((item) => item.sequence)).toEqual([7, 6, 5])
  })

  it('keeps REST presentation order when an existing alert resolves', () => {
    const newer = alert(4, { id: 'a2', startedAt: '2026-09-11T08:02:00Z' })
    const older = alert(2, { id: 'a1', startedAt: '2026-09-11T08:00:00Z' })
    const resolvedOlder = alert(5, {
      id: 'a1',
      state: 'resolved',
      resolvedAt: '2026-09-11T08:05:00Z',
      startedAt: older.startedAt,
    })

    const store = mergeAlert(createAlertStore([newer, older]), resolvedOlder)

    expect(selectRecentAlerts(store, 20)).toEqual([newer, resolvedOlder])
  })

  it('orders out-of-order new ids by sequence without moving existing ids on update', () => {
    const snapshot = alert(3, { id: 'snapshot' })
    let store = createAlertStore([snapshot])
    store = mergeAlert(store, alert(7, { id: 'newer' }))
    store = mergeAlert(store, alert(6, { id: 'older' }))

    expect(selectRecentAlerts(store, 20).map((item) => item.id)).toEqual([
      'newer',
      'older',
      'snapshot',
    ])
  })
})
