import { describe, expect, it } from 'vitest'
import {
  aggregateLatestValue,
  devicesWithChannel,
  maxOf,
  mergeHistorySeries,
  sumOf,
  toSparklinePoints,
} from './metrics'
import type { Device, HistoryPoint, Reading } from '../types/domain'

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

function reading(deviceId: string, channel: string, value: number): Reading {
  return { deviceId, channel, value, unit: 'unit', timestamp: '2026-09-11T08:00:00Z' }
}

describe('devicesWithChannel', () => {
  it('returns only devices whose channel list includes the given channel', () => {
    const rack = device({ deviceId: 'rack-a1', channels: [{ channel: 'exhaust_temp', unit: '°C' }] })
    const ups = device({ deviceId: 'ups-1', kind: 'ups', channels: [{ channel: 'battery_pct', unit: '%' }] })
    expect(devicesWithChannel([rack, ups], 'exhaust_temp')).toEqual([rack])
  })

  it('returns an empty array when no device has the channel', () => {
    const rack = device({ channels: [{ channel: 'exhaust_temp', unit: '°C' }] })
    expect(devicesWithChannel([rack], 'battery_pct')).toEqual([])
  })
})

describe('maxOf / sumOf', () => {
  it('maxOf returns the largest value', () => {
    expect(maxOf([31.2, 33.1, 29.5])).toBe(33.1)
  })

  it('sumOf adds every value', () => {
    expect(sumOf([1180, 1340, 2360])).toBe(4880)
  })
})

describe('aggregateLatestValue', () => {
  it('combines numeric readings across contributing devices', () => {
    const latest: Record<string, Reading> = {
      'rack-a1::exhaust_temp': reading('rack-a1', 'exhaust_temp', 31.2),
      'rack-a2::exhaust_temp': reading('rack-a2', 'exhaust_temp', 33.1),
    }
    const result = aggregateLatestValue(['rack-a1', 'rack-a2'], 'exhaust_temp', latest, maxOf)
    expect(result).toBe(33.1)
  })

  it('sums across contributing devices for a power-draw style metric', () => {
    const latest: Record<string, Reading> = {
      'rack-a1::power_draw': reading('rack-a1', 'power_draw', 1180),
      'rack-a2::power_draw': reading('rack-a2', 'power_draw', 1340),
      'pdu-a1::power_draw': reading('pdu-a1', 'power_draw', 2360),
    }
    const result = aggregateLatestValue(['rack-a1', 'rack-a2', 'pdu-a1'], 'power_draw', latest, sumOf)
    expect(result).toBe(4880)
  })

  it('returns null when none of the contributing keys have a live reading yet', () => {
    const result = aggregateLatestValue(['rack-a1'], 'exhaust_temp', {}, maxOf)
    expect(result).toBeNull()
  })

  it('ignores non-numeric values (e.g. a door_contact-style string reading)', () => {
    const latest: Record<string, Reading> = {
      'rack-a1::door_contact': { deviceId: 'rack-a1', channel: 'door_contact', value: 'closed', unit: 'state', timestamp: 't' },
    }
    const result = aggregateLatestValue(['rack-a1'], 'door_contact', latest, maxOf)
    expect(result).toBeNull()
  })

  it('aggregates over whichever contributing devices do have a reading, skipping the rest', () => {
    const latest: Record<string, Reading> = {
      'rack-a1::exhaust_temp': reading('rack-a1', 'exhaust_temp', 31.2),
    }
    const result = aggregateLatestValue(['rack-a1', 'rack-a2'], 'exhaust_temp', latest, maxOf)
    expect(result).toBe(31.2)
  })
})

describe('toSparklinePoints', () => {
  it('maps history points to sparkline points using avg', () => {
    const points: HistoryPoint[] = [{ t: 't1', avg: 22, min: 20, max: 24 }]
    expect(toSparklinePoints(points)).toEqual([{ t: 't1', value: 22 }])
  })

  it('passes through a null avg', () => {
    const points: HistoryPoint[] = [{ t: 't1', avg: null, min: null, max: null }]
    expect(toSparklinePoints(points)).toEqual([{ t: 't1', value: null }])
  })
})

describe('mergeHistorySeries', () => {
  it('combines aligned buckets across series by timestamp', () => {
    const rackA1: HistoryPoint[] = [
      { t: '2026-09-11T08:00:00Z', avg: 31, min: 30, max: 32 },
      { t: '2026-09-11T08:01:00Z', avg: 32, min: 31, max: 33 },
    ]
    const rackA2: HistoryPoint[] = [
      { t: '2026-09-11T08:00:00Z', avg: 33, min: 32, max: 34 },
      { t: '2026-09-11T08:01:00Z', avg: 30, min: 29, max: 31 },
    ]
    const result = mergeHistorySeries([rackA1, rackA2], maxOf)
    expect(result).toEqual([
      { t: '2026-09-11T08:00:00Z', value: 33 },
      { t: '2026-09-11T08:01:00Z', value: 32 },
    ])
  })

  it('sorts merged buckets chronologically even if the input series are not aligned in order', () => {
    const series: HistoryPoint[] = [
      { t: '2026-09-11T08:01:00Z', avg: 2, min: 2, max: 2 },
      { t: '2026-09-11T08:00:00Z', avg: 1, min: 1, max: 1 },
    ]
    expect(mergeHistorySeries([series], sumOf)).toEqual([
      { t: '2026-09-11T08:00:00Z', value: 1 },
      { t: '2026-09-11T08:01:00Z', value: 2 },
    ])
  })

  it('combines whichever series have data at a bucket a sparser series is missing', () => {
    const rackA1: HistoryPoint[] = [
      { t: '2026-09-11T08:00:00Z', avg: 10, min: 10, max: 10 },
      { t: '2026-09-11T08:01:00Z', avg: 20, min: 20, max: 20 },
    ]
    const rackA2: HistoryPoint[] = [{ t: '2026-09-11T08:00:00Z', avg: 5, min: 5, max: 5 }]
    expect(mergeHistorySeries([rackA1, rackA2], sumOf)).toEqual([
      { t: '2026-09-11T08:00:00Z', value: 15 },
      { t: '2026-09-11T08:01:00Z', value: 20 },
    ])
  })

  it('skips a null-avg point rather than treating it as zero', () => {
    const series: HistoryPoint[] = [{ t: '2026-09-11T08:00:00Z', avg: null, min: null, max: null }]
    expect(mergeHistorySeries([series], sumOf)).toEqual([])
  })

  it('returns an empty array for no series data', () => {
    expect(mergeHistorySeries([], maxOf)).toEqual([])
    expect(mergeHistorySeries([[]], maxOf)).toEqual([])
  })
})
