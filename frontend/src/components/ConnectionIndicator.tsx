import type { ConnectionState } from '../types/domain'
import { Badge, type BadgeVariant } from './Badge'

const LABEL: Record<ConnectionState, string> = {
  connecting: 'Connecting',
  connected: 'Connected',
  reconnecting: 'Reconnecting',
  disconnected: 'Disconnected',
}

const VARIANT: Record<ConnectionState, BadgeVariant> = {
  connecting: 'neutral',
  connected: 'ok',
  reconnecting: 'warning',
  disconnected: 'critical',
}

export interface ConnectionIndicatorProps {
  state: ConnectionState
}

export function ConnectionIndicator({ state }: ConnectionIndicatorProps) {
  return (
    <Badge variant={VARIANT[state]}>
      <span aria-hidden="true">●</span> {LABEL[state]}
    </Badge>
  )
}
