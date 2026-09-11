import { useEffect, useState } from 'react'

/**
 * One shared page-level clock, ticking every `intervalMs`, for rendering
 * relative timestamps (see lib/relativeTime.ts) without a timer per row.
 */
export function useClockTick(intervalMs: number): Date {
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])

  return now
}
