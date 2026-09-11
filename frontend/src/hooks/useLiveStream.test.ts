import { act, renderHook } from '@testing-library/react'
import { StrictMode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MockWebSocket } from '../test/MockWebSocket'
import { useLiveStream } from './useLiveStream'

const READING_A = {
  deviceId: 'rack-a1',
  channel: 'intake_temp',
  value: 21.4,
  unit: '°C',
  timestamp: '2026-09-11T10:00:00Z',
}

const ALERT_A = {
  id: '65f0000000000000000000a1',
  ruleId: 'rack-a1-high-temp',
  deviceId: 'rack-a1',
  channel: 'intake_temp',
  severity: 'critical' as const,
  state: 'firing' as const,
  triggeredValue: 32.1,
  lastValue: 32.1,
  startedAt: '2026-09-11T10:00:00Z',
  resolvedAt: null,
}

function currentSocket(): MockWebSocket {
  const socket = MockWebSocket.instances.at(-1)
  if (!socket) {
    throw new Error('no MockWebSocket instance was created')
  }
  return socket
}

beforeEach(() => {
  vi.useFakeTimers()
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('useLiveStream', () => {
  it('opens exactly one socket to /ws/sensors', () => {
    renderHook(() => useLiveStream())

    expect(MockWebSocket.instances).toHaveLength(1)
    expect(MockWebSocket.instances[0].url).toContain('/ws/sensors')
  })

  it('starts in the connecting state', () => {
    const { result } = renderHook(() => useLiveStream())
    expect(result.current.connectionState).toBe('connecting')
  })

  it('transitions to connected on open', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())
    expect(result.current.connectionState).toBe('connected')
  })

  it('dispatches a reading envelope into latestReadings, keyed by deviceId+channel', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())

    act(() =>
      currentSocket().triggerMessage(JSON.stringify({ kind: 'reading', payload: READING_A })),
    )

    expect(result.current.latestReadings['rack-a1::intake_temp']).toEqual(READING_A)
  })

  it('dispatches an alert envelope into the alerts buffer, newest first', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())

    act(() => currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload: ALERT_A })))

    expect(result.current.alerts[0]).toEqual(ALERT_A)
  })

  it('ignores a malformed JSON message without changing state', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())

    act(() => currentSocket().triggerMessage('{not json'))

    expect(result.current.latestReadings).toEqual({})
    expect(result.current.alerts).toEqual([])
    expect(result.current.connectionState).toBe('connected')
  })

  it('ignores a malformed known-kind payload without changing state', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())

    act(() =>
      currentSocket().triggerMessage(
        JSON.stringify({ kind: 'reading', payload: { deviceId: 'rack-a1' } }),
      ),
    )

    expect(result.current.latestReadings).toEqual({})
  })

  it('ignores an unknown kind without changing state', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())

    act(() =>
      currentSocket().triggerMessage(JSON.stringify({ kind: 'ping', payload: READING_A })),
    )

    expect(result.current.latestReadings).toEqual({})
    expect(result.current.alerts).toEqual([])
  })

  it('moves to reconnecting on an unexpected close', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())

    act(() => currentSocket().triggerClose())

    expect(result.current.connectionState).toBe('reconnecting')
  })

  it('clears latestReadings on an unexpected close', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())
    act(() =>
      currentSocket().triggerMessage(JSON.stringify({ kind: 'reading', payload: READING_A })),
    )

    act(() => currentSocket().triggerClose())

    expect(result.current.latestReadings).toEqual({})
  })

  it('clears the live alerts buffer on an unexpected close', () => {
    const { result } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())
    act(() => currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload: ALERT_A })))

    act(() => currentSocket().triggerClose())

    expect(result.current.alerts).toEqual([])
  })

  it('reconnects using deterministic 1/2/4/8/10 second backoff, capped', () => {
    renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())
    act(() => currentSocket().triggerClose()) // schedules retry #1 at 1000ms

    expect(MockWebSocket.instances).toHaveLength(1)
    act(() => vi.advanceTimersByTime(999))
    expect(MockWebSocket.instances).toHaveLength(1)
    act(() => vi.advanceTimersByTime(1))
    expect(MockWebSocket.instances).toHaveLength(2)

    act(() => currentSocket().triggerClose()) // schedules retry #2 at 2000ms
    act(() => vi.advanceTimersByTime(1999))
    expect(MockWebSocket.instances).toHaveLength(2)
    act(() => vi.advanceTimersByTime(1))
    expect(MockWebSocket.instances).toHaveLength(3)

    act(() => currentSocket().triggerClose()) // retry #3 at 4000ms
    act(() => vi.advanceTimersByTime(4000))
    expect(MockWebSocket.instances).toHaveLength(4)

    act(() => currentSocket().triggerClose()) // retry #4 at 8000ms
    act(() => vi.advanceTimersByTime(8000))
    expect(MockWebSocket.instances).toHaveLength(5)

    act(() => currentSocket().triggerClose()) // retry #5 at 10000ms (capped)
    act(() => vi.advanceTimersByTime(10000))
    expect(MockWebSocket.instances).toHaveLength(6)

    act(() => currentSocket().triggerClose()) // retry #6 stays capped at 10000ms
    act(() => vi.advanceTimersByTime(9999))
    expect(MockWebSocket.instances).toHaveLength(6)
    act(() => vi.advanceTimersByTime(1))
    expect(MockWebSocket.instances).toHaveLength(7)
  })

  it('resets the retry delay to 1 second after a successful reconnect', () => {
    renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())
    act(() => currentSocket().triggerClose()) // -> retry at 1000ms
    act(() => vi.advanceTimersByTime(1000)) // socket #2 created
    act(() => currentSocket().triggerOpen()) // successful reconnect resets delay

    act(() => currentSocket().triggerClose()) // should schedule at 1000ms again, not 2000ms
    act(() => vi.advanceTimersByTime(999))
    expect(MockWebSocket.instances).toHaveLength(2)
    act(() => vi.advanceTimersByTime(1))
    expect(MockWebSocket.instances).toHaveLength(3)
  })

  it('schedules only one reconnect timer at a time', () => {
    renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())
    act(() => currentSocket().triggerClose())

    expect(vi.getTimerCount()).toBe(1)
  })

  it('cancels a pending reconnect on unmount', () => {
    const { unmount } = renderHook(() => useLiveStream())
    act(() => currentSocket().triggerOpen())
    act(() => currentSocket().triggerClose()) // schedules retry at 1000ms

    unmount()
    act(() => vi.advanceTimersByTime(10_000))

    expect(MockWebSocket.instances).toHaveLength(1)
  })

  it('does not reconnect when the close was caused by unmount', () => {
    const { unmount } = renderHook(() => useLiveStream())
    const socket = currentSocket()
    act(() => socket.triggerOpen())

    unmount() // calls socket.close() via cleanup; the close event itself arrives later
    expect(socket.closeRequested).toBe(true)
    expect(MockWebSocket.instances).toHaveLength(1)

    // Real browsers deliver the close event asynchronously -- simulate it
    // arriving after cleanup has already run.
    act(() => socket.triggerClose())
    act(() => vi.advanceTimersByTime(10_000))

    expect(MockWebSocket.instances).toHaveLength(1)
  })

  it('ignores a stale onopen from a socket that a reconnect has already replaced', () => {
    const { result } = renderHook(() => useLiveStream())
    const firstSocket = currentSocket()
    act(() => firstSocket.triggerOpen())
    act(() => firstSocket.triggerClose()) // schedules a reconnect at 1000ms
    act(() => vi.advanceTimersByTime(1000)) // reconnect creates socket #2

    expect(MockWebSocket.instances).toHaveLength(2)
    const secondSocket = currentSocket()
    expect(secondSocket).not.toBe(firstSocket)

    // A stale open from the superseded first socket must not touch state.
    act(() => firstSocket.triggerOpen())
    expect(result.current.connectionState).toBe('reconnecting')

    act(() => secondSocket.triggerOpen())
    expect(result.current.connectionState).toBe('connected')
  })

  it('ignores a stale onmessage from a socket that a reconnect has already replaced', () => {
    const { result } = renderHook(() => useLiveStream())
    const firstSocket = currentSocket()
    act(() => firstSocket.triggerOpen())
    act(() => firstSocket.triggerClose())
    act(() => vi.advanceTimersByTime(1000))
    const secondSocket = currentSocket()
    act(() => secondSocket.triggerOpen())

    // A stale message from the superseded first socket must be ignored.
    act(() =>
      firstSocket.triggerMessage(JSON.stringify({ kind: 'reading', payload: READING_A })),
    )
    expect(result.current.latestReadings).toEqual({})

    act(() =>
      secondSocket.triggerMessage(JSON.stringify({ kind: 'reading', payload: READING_A })),
    )
    expect(result.current.latestReadings['rack-a1::intake_temp']).toEqual(READING_A)
  })

  it('does not schedule a second reconnect timer if a close event is somehow delivered twice', () => {
    renderHook(() => useLiveStream())
    const socket = currentSocket()
    act(() => socket.triggerOpen())

    act(() => socket.onclose?.())
    expect(vi.getTimerCount()).toBe(1)

    // A second, redundant delivery of the same socket's close handler (the
    // mock's own guard would normally prevent this, so call onclose directly
    // to prove the hook's own logic is also defensive here).
    act(() => socket.onclose?.())
    expect(vi.getTimerCount()).toBe(1)
    expect(MockWebSocket.instances).toHaveLength(1)
  })

  it('survives React StrictMode double-invoking the effect without leaking a stale reconnect', () => {
    const { result, unmount } = renderHook(() => useLiveStream(), { wrapper: StrictMode })

    // Dev-only StrictMode mounts the effect, cleans it up, then mounts it
    // again -- this must produce two sockets, not more, and the first one's
    // close() (called by the first cleanup) must not have delivered its
    // close event synchronously (see MockWebSocket#close).
    expect(MockWebSocket.instances).toHaveLength(2)
    const [socketA, socketB] = MockWebSocket.instances
    expect(socketA.closeRequested).toBe(true)
    expect(socketB.closeRequested).toBe(false)

    act(() => socketB.triggerOpen())
    expect(result.current.connectionState).toBe('connected')

    // The real-world race this regression covers: A's close event arrives
    // asynchronously, AFTER B already exists and is connected.
    act(() => socketA.triggerClose())

    // A stale close from the superseded first-effect-instance socket must
    // not touch state or schedule a reconnect.
    expect(result.current.connectionState).toBe('connected')
    expect(vi.getTimerCount()).toBe(0)

    act(() => vi.advanceTimersByTime(15_000))
    expect(MockWebSocket.instances).toHaveLength(2) // no socket C

    // B remains the one live, wired-up socket.
    act(() =>
      socketB.triggerMessage(JSON.stringify({ kind: 'reading', payload: READING_A })),
    )
    expect(result.current.latestReadings['rack-a1::intake_temp']).toEqual(READING_A)

    // A stale message from the superseded A must be ignored too.
    act(() => socketA.triggerMessage(JSON.stringify({ kind: 'alert', payload: ALERT_A })))
    expect(result.current.alerts).toEqual([])

    unmount()
    expect(socketB.closeRequested).toBe(true)
    act(() => socketB.triggerClose())
    act(() => vi.advanceTimersByTime(15_000))
    expect(MockWebSocket.instances).toHaveLength(2) // still no reconnect after final unmount
  })
})
