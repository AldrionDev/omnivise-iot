import { describe, expect, it } from 'vitest'
import { formatRelativeTime } from './relativeTime'

const NOW = new Date('2026-09-11T09:00:00Z')

describe('formatRelativeTime', () => {
  it('shows "just now" for a timestamp under a minute old', () => {
    expect(formatRelativeTime('2026-09-11T08:59:30Z', NOW)).toBe('just now')
  })

  it('shows "just now" at exactly 0 seconds old', () => {
    expect(formatRelativeTime('2026-09-11T09:00:00Z', NOW)).toBe('just now')
  })

  it('shows minutes for a timestamp under an hour old', () => {
    expect(formatRelativeTime('2026-09-11T08:55:00Z', NOW)).toBe('5m ago')
  })

  it('floors partial minutes', () => {
    expect(formatRelativeTime('2026-09-11T08:55:59Z', NOW)).toBe('4m ago')
  })

  it('shows "just now" at the boundary just under one minute', () => {
    expect(formatRelativeTime('2026-09-11T08:59:01Z', NOW)).toBe('just now')
  })

  it('shows hours for a timestamp under a day old', () => {
    expect(formatRelativeTime('2026-09-11T06:00:00Z', NOW)).toBe('3h ago')
  })

  it('switches from minutes to hours at exactly 60 minutes', () => {
    expect(formatRelativeTime('2026-09-11T08:00:00Z', NOW)).toBe('1h ago')
  })

  it('shows days for a timestamp a day or more old', () => {
    expect(formatRelativeTime('2026-09-08T09:00:00Z', NOW)).toBe('3d ago')
  })

  it('switches from hours to days at exactly 24 hours', () => {
    expect(formatRelativeTime('2026-09-10T09:00:00Z', NOW)).toBe('1d ago')
  })

  it('treats a future timestamp (clock skew) as "just now" instead of negative', () => {
    expect(formatRelativeTime('2026-09-11T09:05:00Z', NOW)).toBe('just now')
  })
})
