import { useEffect, useEffectEvent } from 'react'
import { useLiveStreamContext } from './LiveStreamContext'
import type { AlertEvent } from '../types/domain'

/** Subscribes directly to every validated alert frame without render buffering. */
export function useLiveAlertTransitions(onAlert: (alert: AlertEvent) => void): void {
  const { subscribeToAlerts } = useLiveStreamContext()
  const handleAlert = useEffectEvent(onAlert)

  useEffect(
    () => subscribeToAlerts((alert) => handleAlert(alert)),
    [subscribeToAlerts],
  )
}
