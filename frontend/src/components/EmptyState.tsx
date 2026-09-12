import type { ReactNode } from 'react'

export interface EmptyStateProps {
  title: string
  description?: string
  icon?: ReactNode
  action?: ReactNode
}

/** Presentational placeholder for "nothing to show yet" states. */
export function EmptyState({ title, description, icon, action }: EmptyStateProps) {
  return (
    <div className="flex flex-col items-center gap-sm py-xl text-center text-muted">
      {icon}
      <p className="text-lg text-foreground">{title}</p>
      {description && <p className="text-sm">{description}</p>}
      {action}
    </div>
  )
}
