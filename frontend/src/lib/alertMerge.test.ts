import { describe, expect, it } from 'vitest'
import { mergeActiveAlert, mergeRecentAlert, replayActiveAlerts, replayRecentAlerts } from './alertMerge'
import type { AlertEvent } from '../types/domain'

function alert(overrides: Partial<AlertEvent>): AlertEvent {
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

describe('mergeRecentAlert', () => {
  it('inserts a genuinely new id at the front', () => {
    const existing = [alert({ id: 'old' })]
    const incoming = alert({ id: 'new' })
    expect(mergeRecentAlert(existing, incoming)).toEqual([incoming, ...existing])
  })

  it('replaces an existing id in place without duplicating it', () => {
    const existing = [alert({ id: 'x' }), alert({ id: 'a1', state: 'firing' })]
    const resolved = alert({ id: 'a1', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })

    const result = mergeRecentAlert(existing, resolved)

    expect(result).toHaveLength(2)
    expect(result[1]).toEqual(resolved)
    expect(result.filter((a) => a.id === 'a1')).toHaveLength(1)
  })

  it('caps the result at the given limit', () => {
    const existing = Array.from({ length: 20 }, (_, i) => alert({ id: `id-${i}` }))
    const incoming = alert({ id: 'new-one' })

    const result = mergeRecentAlert(existing, incoming, 20)

    expect(result).toHaveLength(20)
    expect(result[0]).toEqual(incoming)
  })
})

describe('mergeActiveAlert', () => {
  it('upserts a firing alert by id', () => {
    const existing = [alert({ id: 'a1', severity: 'warning' })]
    const incoming = alert({ id: 'a2', severity: 'critical' })

    const result = mergeActiveAlert(existing, incoming)

    expect(result).toContainEqual(incoming)
    expect(result).toContainEqual(existing[0])
  })

  it('replaces an existing id rather than duplicating it', () => {
    const existing = [alert({ id: 'a1', lastValue: 31 })]
    const incoming = alert({ id: 'a1', lastValue: 33 })

    const result = mergeActiveAlert(existing, incoming)

    expect(result).toHaveLength(1)
    expect(result[0]).toEqual(incoming)
  })

  it('removes the alert by id on resolved', () => {
    const existing = [alert({ id: 'a1' }), alert({ id: 'a2' })]
    const resolved = alert({ id: 'a1', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })

    const result = mergeActiveAlert(existing, resolved)

    expect(result).toEqual([existing[1]])
  })

  it('resolving an id that is not present is a no-op', () => {
    const existing = [alert({ id: 'a1' })]
    const resolved = alert({ id: 'unknown', state: 'resolved' })

    expect(mergeActiveAlert(existing, resolved)).toEqual(existing)
  })
})

describe('replayActiveAlerts', () => {
  it('applies buffered transitions in order on top of a snapshot', () => {
    const snapshot: AlertEvent[] = []
    const firing = alert({ id: 'a1', state: 'firing' })
    const resolved = alert({ id: 'a1', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })

    const result = replayActiveAlerts(snapshot, [firing, resolved])

    expect(result).toEqual([])
  })

  it('leaves the alert active when only the firing transition replays', () => {
    const result = replayActiveAlerts([], [alert({ id: 'a1', state: 'firing' })])
    expect(result).toEqual([alert({ id: 'a1', state: 'firing' })])
  })

  it('is a no-op when the buffer is empty', () => {
    const snapshot = [alert({ id: 'a1' })]
    expect(replayActiveAlerts(snapshot, [])).toEqual(snapshot)
  })

  it('reinstates an alert the snapshot predates', () => {
    // snapshot was queried before the alert fired
    const snapshot: AlertEvent[] = []
    const firing = alert({ id: 'new', severity: 'critical', state: 'firing' })

    expect(replayActiveAlerts(snapshot, [firing])).toEqual([firing])
  })

  it('does not duplicate when the snapshot already contains the buffered event', () => {
    const firing = alert({ id: 'a1', state: 'firing' })
    const snapshot = [firing]

    const result = replayActiveAlerts(snapshot, [firing])

    expect(result).toEqual([firing])
  })
})

describe('replayRecentAlerts', () => {
  it('applies a firing-then-resolved pair, ending with exactly one resolved row', () => {
    const firing = alert({ id: 'a1', state: 'firing' })
    const resolved = alert({ id: 'a1', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })

    const result = replayRecentAlerts([], [firing, resolved])

    expect(result).toEqual([resolved])
  })

  it('inserts a genuinely new id at the front, preserving existing order', () => {
    const snapshot = [alert({ id: 'old' })]
    const incoming = alert({ id: 'new' })

    const result = replayRecentAlerts(snapshot, [incoming])

    expect(result).toEqual([incoming, ...snapshot])
  })

  it('respects the limit after replay', () => {
    const snapshot = Array.from({ length: 20 }, (_, i) => alert({ id: `id-${i}` }))
    const incoming = alert({ id: 'brand-new' })

    const result = replayRecentAlerts(snapshot, [incoming], 20)

    expect(result).toHaveLength(20)
    expect(result[0]).toEqual(incoming)
  })

  it('is a no-op when the buffer is empty', () => {
    const snapshot = [alert({ id: 'a1' })]
    expect(replayRecentAlerts(snapshot, [])).toEqual(snapshot)
  })
})
