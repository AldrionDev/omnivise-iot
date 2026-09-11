import { Line, LineChart, ResponsiveContainer } from 'recharts'
import type { SparklinePoint } from '../lib/metrics'

export type SparklineStatus = 'loading' | 'error' | 'ready'

export interface SparklineProps {
  status: SparklineStatus
  points: SparklinePoint[]
}

/**
 * Small reusable trend line for Overview headline metrics (issue #76) --
 * deliberately minimal (no axes/grid/tooltip) compared to TimeSeriesChart.
 * Colors are `var(--ov-color-*)` strings resolved by the browser at paint
 * time, so no theme state/variants are needed here either.
 */
export function Sparkline({ status, points }: SparklineProps) {
  if (status === 'loading') {
    return <p className="text-sm text-muted">Loading trend…</p>
  }

  if (status === 'error') {
    return <p className="text-sm text-status-critical">Couldn't load trend.</p>
  }

  if (points.length === 0 || points.every((point) => point.value === null)) {
    return <p className="text-sm text-muted">No data for this range.</p>
  }

  return (
    <ResponsiveContainer width="100%" height={40}>
      <LineChart data={points} margin={{ top: 4, right: 4, bottom: 4, left: 4 }}>
        <Line
          dataKey="value"
          stroke="var(--ov-color-accent)"
          strokeWidth={2}
          dot={false}
          isAnimationActive={false}
          connectNulls
        />
      </LineChart>
    </ResponsiveContainer>
  )
}
