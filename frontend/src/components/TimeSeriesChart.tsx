import {
  Area,
  CartesianGrid,
  ComposedChart,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import type { HistoryPoint } from '../types/domain'

export type TimeSeriesChartStatus = 'loading' | 'error' | 'ready'

export interface TimeSeriesChartProps {
  status: TimeSeriesChartStatus
  unit: string
  points: HistoryPoint[]
}

function formatTime(isoTimestamp: string): string {
  return new Date(isoTimestamp).toLocaleTimeString(undefined, {
    hour: '2-digit',
    minute: '2-digit',
  })
}

function minMaxRange(point: HistoryPoint): [number | null, number | null] {
  return [point.min, point.max]
}

/**
 * Reusable single-channel time-series chart (issue #75). Colors are passed as
 * `var(--ov-color-*)` strings straight to SVG attributes -- the browser
 * resolves the CSS custom property at paint time, so this needs no theme
 * state or light/dark component variants (see styles/tokens.css).
 */
export function TimeSeriesChart({ status, unit, points }: TimeSeriesChartProps) {
  if (status === 'loading') {
    return <p className="text-sm text-muted">Loading chart…</p>
  }

  if (status === 'error') {
    return <p className="text-sm text-status-critical">Couldn't load chart data.</p>
  }

  if (points.length === 0) {
    return <p className="text-sm text-muted">No data for this range.</p>
  }

  return (
    <ResponsiveContainer width="100%" height={220}>
      <ComposedChart data={points} margin={{ top: 8, right: 8, bottom: 8, left: 8 }}>
        <CartesianGrid stroke="var(--ov-color-border)" strokeDasharray="3 3" />
        <XAxis
          dataKey="t"
          tickFormatter={formatTime}
          stroke="var(--ov-color-border)"
          tick={{ fill: 'var(--ov-color-muted)', fontSize: 12 }}
        />
        <YAxis
          unit={` ${unit}`}
          stroke="var(--ov-color-border)"
          tick={{ fill: 'var(--ov-color-muted)', fontSize: 12 }}
          width={64}
        />
        <Tooltip
          labelFormatter={(label) => (typeof label === 'string' ? formatTime(label) : label)}
          formatter={(value) => (typeof value === 'number' ? `${value} ${unit}` : value)}
          contentStyle={{
            background: 'var(--ov-color-surface)',
            border: '1px solid var(--ov-color-border)',
            borderRadius: 4,
          }}
          labelStyle={{ color: 'var(--ov-color-foreground)' }}
        />
        <Area
          dataKey={minMaxRange}
          stroke="none"
          fill="var(--ov-color-accent)"
          fillOpacity={0.15}
          isAnimationActive={false}
          connectNulls
        />
        <Line
          dataKey="avg"
          stroke="var(--ov-color-accent)"
          strokeWidth={2}
          dot={false}
          isAnimationActive={false}
          connectNulls
        />
      </ComposedChart>
    </ResponsiveContainer>
  )
}
