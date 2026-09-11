import { cn } from '../lib/cn'

export interface StatDeltaProps {
  value: number
}

function formatSigned(value: number): string {
  if (value > 0) {
    return `+${value}`
  }
  return `${value}`
}

/**
 * A signed delta indicator. Color alone never carries the meaning: the sign
 * is in the visible text, and the direction is spelled out for screen
 * readers too (an arrow/color-only cue would be inaccessible).
 */
export function StatDelta({ value }: StatDeltaProps) {
  const tone = value > 0 ? 'text-status-ok' : value < 0 ? 'text-status-critical' : 'text-muted'
  const direction = value > 0 ? 'increased by' : value < 0 ? 'decreased by' : 'unchanged'

  return (
    <span className={cn('inline-flex items-center gap-xs text-sm', tone)}>
      <span className="sr-only">{direction}</span>
      {formatSigned(value)}
    </span>
  )
}
