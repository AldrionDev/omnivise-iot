import { useState } from 'react'
import { useLiveStreamContext } from './LiveStreamContext'
import type { ConnectionState } from '../types/domain'

const RECOVERABLE_STATES: ConnectionState[] = ['reconnecting', 'disconnected']

/**
 * A token that increments exactly when the #74 WebSocket transitions from a
 * disconnected/reconnecting period back to connected -- never on the initial
 * connect, and never on an ordinary render. Transitions may have been missed
 * while disconnected, so consumers add this token to a REST-fetch effect to
 * trigger exactly one authoritative refetch after such a recovery.
 *
 * Adjusts state during render (React's documented pattern for deriving state
 * from a prop/context change) rather than in an effect, so the token is
 * already current by the time dependent effects run in this same commit --
 * no extra render round-trip, and no synchronous setState-in-effect.
 */
export function useReconnectResync(): number {
  const { connectionState } = useLiveStreamContext()
  const [prevConnectionState, setPrevConnectionState] = useState(connectionState)
  const [token, setToken] = useState(0)

  if (connectionState !== prevConnectionState) {
    const recovered = connectionState === 'connected' && RECOVERABLE_STATES.includes(prevConnectionState)
    setPrevConnectionState(connectionState)
    if (recovered) {
      setToken((t) => t + 1)
    }
  }

  return token
}
