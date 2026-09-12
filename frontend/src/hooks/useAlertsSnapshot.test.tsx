import { act, renderHook, waitFor } from '@testing-library/react'
import { StrictMode, type ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useAlertsSnapshot } from './useAlertsSnapshot'
import { LiveStreamProvider } from './LiveStreamContext'
import { MockWebSocket } from '../test/MockWebSocket'
import type { AlertEvent } from '../types/domain'

function alert(sequence: number, overrides: Partial<AlertEvent> = {}): AlertEvent {
  return {
    sequence,
    id: 'a1',
    ruleId: 'r1',
    deviceId: 'rack-a1',
    channel: 'exhaust_temp',
    severity: 'warning',
    state: 'firing',
    triggeredValue: 31,
    lastValue: 31,
    startedAt: '2026-09-11T08:00:00Z',
    resolvedAt: null,
    ...overrides,
  }
}

function response(items: AlertEvent[], watermark: number) {
  return new Response(JSON.stringify(items), {
    status: 200,
    headers: { 'X-Alert-Watermark': String(watermark) },
  })
}

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason?: unknown) => void
  const promise = new Promise<T>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

function currentSocket() {
  const socket = MockWebSocket.instances.at(-1)
  if (!socket) throw new Error('no MockWebSocket instance was created')
  return socket
}

function sendAlert(payload: AlertEvent) {
  act(() => currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload })))
}

function wrapper({ children }: { children: ReactNode }) {
  return <LiveStreamProvider>{children}</LiveStreamProvider>
}

function strictWrapper({ children }: { children: ReactNode }) {
  return <StrictMode><LiveStreamProvider>{children}</LiveStreamProvider></StrictMode>
}

beforeEach(() => {
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
})

afterEach(() => {
  vi.unstubAllGlobals()
  vi.useRealTimers()
})

describe('useAlertsSnapshot synchronization', () => {
  it('rejects malformed snapshots without installing them', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(JSON.stringify([]), { status: 200 }))))
    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
    await waitFor(() => expect(result.current).toEqual({ status: 'error' }))
  })

  it('does not lose A journal entries when B supersedes A and then fails', async () => {
    const requestA = deferred<Response>()
    const requestB = deferred<Response>()
    let call = 0
    vi.stubGlobal('fetch', vi.fn(() => {
      call++
      if (call === 1) return Promise.resolve(response([], 0))
      return call === 2 ? requestA.promise : requestB.promise
    }))
    const { result, rerender } = renderHook(
      ({ refresh }) => useAlertsSnapshot('/alerts/active', 'active', 20, undefined, refresh),
      { wrapper, initialProps: { refresh: 0 } },
    )
    await waitFor(() => expect(result.current.status).toBe('loaded'))
    rerender({ refresh: 1 })
    sendAlert(alert(10))
    rerender({ refresh: 2 })
    requestA.resolve(response([], 10))
    requestB.reject(new Error('network'))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert(10)] }))
  })

  it('delivers more than twenty transitions received in one batch', async () => {
    const initial = deferred<Response>()
    vi.stubGlobal('fetch', vi.fn(() => initial.promise))
    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
    act(() => {
      for (let sequence = 1; sequence <= 25; sequence++) {
        currentSocket().triggerMessage(JSON.stringify({
          kind: 'alert',
          payload: alert(sequence, { id: `a${sequence}` }),
        }))
      }
    })
    initial.resolve(response([], 0))
    await waitFor(() => expect(result.current.status === 'loaded' && result.current.items).toHaveLength(25))
  })

  it('compacts retained tombstones with one event-driven authoritative resync', async () => {
    const compaction = deferred<Response>()
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response([], 0))
      .mockReturnValueOnce(compaction.promise)
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
    await waitFor(() => expect(result.current.status).toBe('loaded'))

    act(() => {
      for (let sequence = 1; sequence <= 1001; sequence++) {
        currentSocket().triggerMessage(JSON.stringify({
          kind: 'alert',
          payload: alert(sequence, {
            id: `resolved-${sequence}`,
            state: 'resolved',
            resolvedAt: '2026-09-11T08:05:00Z',
          }),
        }))
      }
    })

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    compaction.resolve(response([], 1001))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('allows the next transition to retry a failed compaction without polling', async () => {
    const failedCompaction = deferred<Response>()
    const recoveredCompaction = deferred<Response>()
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(response([], 0))
      .mockReturnValueOnce(failedCompaction.promise)
      .mockReturnValueOnce(recoveredCompaction.promise)
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
    await waitFor(() => expect(result.current.status).toBe('loaded'))

    act(() => {
      for (let sequence = 1; sequence <= 1001; sequence++) {
        currentSocket().triggerMessage(JSON.stringify({
          kind: 'alert',
          payload: alert(sequence, {
            id: `resolved-${sequence}`,
            state: 'resolved',
            resolvedAt: '2026-09-11T08:05:00Z',
          }),
        }))
      }
    })
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    failedCompaction.reject(new Error('network'))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))

    sendAlert(alert(1002, {
      id: 'resolved-1002',
      state: 'resolved',
      resolvedAt: '2026-09-11T08:05:00Z',
    }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3))
    recoveredCompaction.resolve(response([], 1002))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))
  })

  it('does not resurrect firing older than a resolved snapshot, even without a correcting WS frame', async () => {
    const initial = deferred<Response>()
    vi.stubGlobal('fetch', vi.fn(() => initial.promise))
    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
    sendAlert(alert(4))
    act(() => currentSocket().triggerClose())
    initial.resolve(response([], 5))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))
  })

  it('keeps firing and resolved for the same id as exactly one resolved recent row', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(response([], 0))))
    const { result } = renderHook(() => useAlertsSnapshot('/alerts', 'recent'), { wrapper })
    await waitFor(() => expect(result.current.status).toBe('loaded'))
    sendAlert(alert(2, { state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }))
    sendAlert(alert(1))
    await waitFor(() => expect(result.current).toEqual({
      status: 'loaded',
      items: [alert(2, { state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })],
    }))
  })

  it('rejects a lower watermark before it mutates loaded state or journal', async () => {
    const stale = deferred<Response>()
    const next = deferred<Response>()
    let call = 0
    vi.stubGlobal('fetch', vi.fn(() => {
      call++
      if (call === 1) return Promise.resolve(response([], 10))
      return call === 2 ? stale.promise : next.promise
    }))
    const { result, rerender } = renderHook(
      ({ refresh }) => useAlertsSnapshot('/alerts/active', 'active', 20, undefined, refresh),
      { wrapper, initialProps: { refresh: 0 } },
    )
    await waitFor(() => expect(result.current.status).toBe('loaded'))
    sendAlert(alert(12))
    rerender({ refresh: 1 })
    stale.resolve(response([], 9))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert(12)] }))
    rerender({ refresh: 2 })
    next.resolve(response([], 10))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert(12)] }))
  })

  it('preserves live-patched state and the unconsumed journal after failed resync', async () => {
    const failed = deferred<Response>()
    const recovered = deferred<Response>()
    let call = 0
    vi.stubGlobal('fetch', vi.fn(() => {
      call++
      if (call === 1) return Promise.resolve(response([], 0))
      return call === 2 ? failed.promise : recovered.promise
    }))
    const { result, rerender } = renderHook(
      ({ refresh }) => useAlertsSnapshot('/alerts/active', 'active', 20, undefined, refresh),
      { wrapper, initialProps: { refresh: 0 } },
    )
    await waitFor(() => expect(result.current.status).toBe('loaded'))
    rerender({ refresh: 1 })
    sendAlert(alert(3))
    failed.reject(new Error('network'))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert(3)] }))
    rerender({ refresh: 2 })
    recovered.resolve(response([], 0))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert(3)] }))
  })

  it('isolates state, journal, and stale responses when device scope changes', async () => {
    const rackA = deferred<Response>()
    const rackB = deferred<Response>()
    vi.stubGlobal('fetch', vi.fn((input: string | URL) => String(input).includes('rack-a1') ? rackA.promise : rackB.promise))
    const { result, rerender } = renderHook(
      ({ deviceId }) => useAlertsSnapshot(`/alerts/active?deviceId=${deviceId}`, 'active', 20, deviceId),
      { wrapper, initialProps: { deviceId: 'rack-a1' } },
    )
    sendAlert(alert(1, { deviceId: 'rack-a1' }))
    rerender({ deviceId: 'rack-b1' })
    sendAlert(alert(2, { id: 'b1', deviceId: 'rack-b1' }))
    rackA.resolve(response([alert(3, { deviceId: 'rack-a1' })], 3))
    rackB.resolve(response([], 0))
    await waitFor(() => expect(result.current).toEqual({
      status: 'loaded',
      items: [alert(2, { id: 'b1', deviceId: 'rack-b1' })],
    }))
  })

  it('remains lossless with pure updaters under StrictMode', async () => {
    const initial = deferred<Response>()
    vi.stubGlobal('fetch', vi.fn(() => initial.promise))
    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper: strictWrapper })
    sendAlert(alert(1))
    initial.resolve(response([], 0))
    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert(1)] }))
  })
})
