import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { Sparkline } from './Sparkline'
import type { SparklinePoint } from '../lib/metrics'

const FIXTURE_POINTS: SparklinePoint[] = [
  { t: '2026-09-11T08:00:00Z', value: 31.2 },
  { t: '2026-09-11T08:01:00Z', value: 31.8 },
]

class StubResizeObserver {
  private readonly callback: ResizeObserverCallback
  constructor(callback: ResizeObserverCallback) {
    this.callback = callback
  }
  observe(target: Element) {
    this.callback([{ contentRect: { width: 200, height: 40 } } as ResizeObserverEntry], this as unknown as ResizeObserver)
    void target
  }
  unobserve() {}
  disconnect() {}
}

beforeEach(() => {
  vi.stubGlobal('ResizeObserver', StubResizeObserver)
})

describe('Sparkline', () => {
  it('shows a loading state', () => {
    render(<Sparkline status="loading" points={[]} />)
    expect(screen.getByText(/loading/i)).toBeTruthy()
  })

  it('shows an explicit error state', () => {
    render(<Sparkline status="error" points={[]} />)
    expect(screen.getByText(/couldn't load/i)).toBeTruthy()
  })

  it('shows an explicit empty state when ready with no points', () => {
    render(<Sparkline status="ready" points={[]} />)
    expect(screen.getByText(/no data/i)).toBeTruthy()
  })

  it('shows an explicit empty state when every point is null', () => {
    render(<Sparkline status="ready" points={[{ t: 't1', value: null }, { t: 't2', value: null }]} />)
    expect(screen.getByText(/no data/i)).toBeTruthy()
  })

  it('renders a line for fixture data', () => {
    const { container } = render(<Sparkline status="ready" points={FIXTURE_POINTS} />)
    expect(container.querySelector('svg')).toBeTruthy()
    expect(container.querySelector('.recharts-line')).toBeTruthy()
  })

  it('renders without throwing when some points are null', () => {
    const withGaps: SparklinePoint[] = [{ t: 't1', value: 10 }, { t: 't2', value: null }, { t: 't3', value: 12 }]
    expect(() => render(<Sparkline status="ready" points={withGaps} />)).not.toThrow()
  })

  it('has no axes/grid chrome (deliberately more minimal than TimeSeriesChart)', () => {
    const { container } = render(<Sparkline status="ready" points={FIXTURE_POINTS} />)
    expect(container.querySelector('.recharts-cartesian-axis')).toBeNull()
    expect(container.querySelector('.recharts-cartesian-grid')).toBeNull()
  })
})
