import type { ReactNode } from 'react'
import { cn } from '../lib/cn'

export interface CardProps {
  children: ReactNode
  className?: string
}

/** Purely presentational surface container. */
export function Card({ children, className }: CardProps) {
  return (
    <div className={cn('rounded-md border border-border bg-surface p-md', className)}>
      {children}
    </div>
  )
}
