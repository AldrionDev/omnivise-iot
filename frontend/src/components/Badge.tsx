import type { ReactNode } from 'react'
import { cn } from '../lib/cn'

export type BadgeVariant = 'neutral' | 'ok' | 'warning' | 'critical'

export interface BadgeProps {
  variant: BadgeVariant
  children: ReactNode
}

const VARIANT_CLASSES: Record<BadgeVariant, string> = {
  neutral: 'bg-surface-raised text-muted',
  ok: 'bg-surface-raised text-status-ok',
  warning: 'bg-surface-raised text-status-warning',
  critical: 'bg-surface-raised text-status-critical',
}

/**
 * Text carries the status, not color alone -- callers must pass a label that
 * makes sense on its own (e.g. "critical"), the variant only tints it.
 */
export function Badge({ variant, children }: BadgeProps) {
  return (
    <span className={cn('inline-flex rounded-sm px-sm py-xs text-sm', VARIANT_CLASSES[variant])}>
      {children}
    </span>
  )
}
