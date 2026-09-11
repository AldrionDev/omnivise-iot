import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { TimeSeriesChart } from './TimeSeriesChart'
import type { HistoryPoint } from '../types/domain'

const FIXTURE_POINTS: HistoryPoint[] = [
  { t: '2026-09-11T08:00:00Z', avg: 22, min: 21, max: 23 },
  { t: '2026-09-11T08:01:00Z', avg: 23, min: 22, max: 24 },
  { t: '2026-09-11T08:02:00Z', avg: 24, min: 23, max: 25 },
]

class StubResizeObserver {
  private readonly callback: ResizeObserverCallback
  constructor(callback: ResizeObserverCallback) {
    this.callback = callback
  }
  observe(target: Element) {
    this.callback(
      [{ contentRect: { width: 400, height: 300 } } as ResizeObserverEntry],
      this as unknown as ResizeObserver,
    )
    void target
  }
  unobserve() {}
  disconnect() {}
}

beforeEach(() => {
  vi.stubGlobal('ResizeObserver', StubResizeObserver)
})

describe('TimeSeriesChart', () => {
  it('shows a loading state while status is loading', () => {
    render(<TimeSeriesChart status="loading" unit="°C" points={[]} />)
    expect(screen.getByText(/loading/i)).toBeTruthy()
  })

  it('shows an explicit error state on status error', () => {
    render(<TimeSeriesChart status="error" unit="°C" points={[]} />)
    expect(screen.getByText(/couldn't load|error|failed/i)).toBeTruthy()
  })

  it('shows an explicit empty state when ready with no points', () => {
    render(<TimeSeriesChart status="ready" unit="°C" points={[]} />)
    expect(screen.getByText(/no data/i)).toBeTruthy()
  })

  it('renders an avg line and a min/max band for fixture data', () => {
    const { container } = render(
      <TimeSeriesChart status="ready" unit="°C" points={FIXTURE_POINTS} />,
    )
    expect(container.querySelector('svg')).toBeTruthy()
    expect(container.querySelector('.recharts-line')).toBeTruthy()
    expect(container.querySelector('.recharts-area')).toBeTruthy()
  })

  it('shows the unit on the axis/tooltip', () => {
    render(<TimeSeriesChart status="ready" unit="°C" points={FIXTURE_POINTS} />)
    expect(screen.getAllByText(/°C/).length).toBeGreaterThan(0)
  })

  it('renders without throwing under both dark and light theme', () => {
    document.documentElement.dataset.theme = 'dark'
    const { unmount } = render(
      <TimeSeriesChart status="ready" unit="°C" points={FIXTURE_POINTS} />,
    )
    unmount()

    document.documentElement.dataset.theme = 'light'
    expect(() =>
      render(<TimeSeriesChart status="ready" unit="°C" points={FIXTURE_POINTS} />),
    ).not.toThrow()

    document.documentElement.removeAttribute('data-theme')
  })
})
