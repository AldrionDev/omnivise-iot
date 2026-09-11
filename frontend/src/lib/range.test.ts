import { describe, expect, it } from 'vitest'
import { resolveHistoryWindow } from './range'

describe('resolveHistoryWindow', () => {
  it('maps 15m to a 1m bucket', () => {
    const to = new Date('2026-09-11T09:00:00.000Z')
    const window = resolveHistoryWindow('15m', to)
    expect(window.bucket).toBe('1m')
  })

  it('maps 1h to a 5m bucket', () => {
    const to = new Date('2026-09-11T09:00:00.000Z')
    expect(resolveHistoryWindow('1h', to).bucket).toBe('5m')
  })

  it('maps 24h to a 1h bucket', () => {
    const to = new Date('2026-09-11T09:00:00.000Z')
    expect(resolveHistoryWindow('24h', to).bucket).toBe('1h')
  })

  it('derives from by subtracting the range duration from the given to', () => {
    const to = new Date('2026-09-11T09:00:00.000Z')
    const window = resolveHistoryWindow('15m', to)
    expect(window.to).toBe('2026-09-11T09:00:00.000Z')
    expect(window.from).toBe('2026-09-11T08:45:00.000Z')
  })

  it('uses ISO-8601 timestamps with a Z zone for both from and to', () => {
    const to = new Date('2026-09-11T09:00:00.000Z')
    const window = resolveHistoryWindow('1h', to)
    expect(window.from).toMatch(/Z$/)
    expect(window.to).toMatch(/Z$/)
  })

  it('gives every range a distinct, well-under-1000-bucket window for 5s-interval data', () => {
    const to = new Date('2026-09-11T09:00:00.000Z')
    expect(resolveHistoryWindow('24h', to).from).toBe('2026-09-10T09:00:00.000Z')
    expect(resolveHistoryWindow('1h', to).from).toBe('2026-09-11T08:00:00.000Z')
  })
})
