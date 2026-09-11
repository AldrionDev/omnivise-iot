import { act, renderHook, waitFor } from '@testing-library/react'
import { StrictMode, type ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useAlertsSnapshot } from './useAlertsSnapshot'
import { LiveStreamProvider } from './LiveStreamContext'
import { MockWebSocket } from '../test/MockWebSocket'
import type { AlertEvent } from '../types/domain'

function alert(overrides: Partial<AlertEvent>): AlertEvent {
  return {
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

function currentSocket(): MockWebSocket {
  const socket = MockWebSocket.instances.at(-1)
  if (!socket) {
    throw new Error('no MockWebSocket instance was created')
  }
  return socket
}

function sendAlert(payload: AlertEvent) {
  act(() => {
    currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload }))
  })
}

function wrapper({ children }: { children: ReactNode }) {
  return <LiveStreamProvider>{children}</LiveStreamProvider>
}

function strictWrapper({ children }: { children: ReactNode }) {
  return (
    <StrictMode>
      <LiveStreamProvider>{children}</LiveStreamProvider>
    </StrictMode>
  )
}

beforeEach(() => {
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('useAlertsSnapshot', () => {
  it('loads the snapshot from the given path', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.resolve(new Response(JSON.stringify([alert({ id: 'a1' })]), { status: 200 }))),
    )

    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })

    await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert({ id: 'a1' })] }))
  })

  it('reports an error state when the initial fetch fails', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response('boom', { status: 500 }))))

    const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })

    await waitFor(() => expect(result.current).toEqual({ status: 'error' }))
  })

  describe('kind="active"', () => {
    it('upserts a firing alert live and removes it once resolved', async () => {
      vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(JSON.stringify([]), { status: 200 }))))
      const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
      await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))
      currentSocket().triggerOpen()

      sendAlert(alert({ id: 'c1', state: 'firing' }))
      await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert({ id: 'c1', state: 'firing' })] }))

      sendAlert(alert({ id: 'c1', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }))
      await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))
    })

    it('does not lose a firing alert that arrives while the initial snapshot is loading', async () => {
      let resolveActive: ((value: Response) => void) | undefined
      const pending = new Promise<Response>((resolve) => {
        resolveActive = resolve
      })
      vi.stubGlobal('fetch', vi.fn(() => pending))

      const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
      expect(result.current).toEqual({ status: 'loading' })
      currentSocket().triggerOpen()

      sendAlert(alert({ id: 'live-1', state: 'firing' }))

      act(() => resolveActive?.(new Response(JSON.stringify([]), { status: 200 })))

      await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert({ id: 'live-1', state: 'firing' })] }))
    })
  })

  describe('kind="recent"', () => {
    it('prepends a genuinely new id and updates an existing id in place without duplicating', async () => {
      vi.stubGlobal(
        'fetch',
        vi.fn(() => Promise.resolve(new Response(JSON.stringify([alert({ id: 'old' })]), { status: 200 }))),
      )
      const { result } = renderHook(() => useAlertsSnapshot('/alerts', 'recent', 20), { wrapper })
      await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [alert({ id: 'old' })] }))
      currentSocket().triggerOpen()

      sendAlert(alert({ id: 'new', state: 'firing' }))
      await waitFor(() =>
        expect(result.current).toEqual({
          status: 'loaded',
          items: [alert({ id: 'new', state: 'firing' }), alert({ id: 'old' })],
        }),
      )

      sendAlert(alert({ id: 'old', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }))
      await waitFor(() =>
        expect(result.current).toEqual({
          status: 'loaded',
          items: [alert({ id: 'new', state: 'firing' }), alert({ id: 'old', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' })],
        }),
      )
    })
  })

  describe('reconnect resync', () => {
    beforeEach(() => vi.useFakeTimers())
    afterEach(() => vi.useRealTimers())

    it('refetches the snapshot exactly once after a reconnect', async () => {
      vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(JSON.stringify([]), { status: 200 }))))
      const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), { wrapper })
      await vi.waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))

      const callsBefore = vi.mocked(fetch).mock.calls.length
      const firstSocket = currentSocket()
      firstSocket.triggerOpen()
      firstSocket.triggerClose()
      await vi.advanceTimersByTimeAsync(1000)
      currentSocket().triggerOpen()

      await vi.waitFor(() => expect(vi.mocked(fetch).mock.calls.length).toBe(callsBefore + 1))
    })
  })

  describe('resync failure preserves buffered alerts under StrictMode (issue #75 B1)', () => {
    it('keeps a firing alert reflected after a resync that then fails', async () => {
      let resyncArmed = false
      let rejectResync: ((reason?: unknown) => void) | undefined
      vi.stubGlobal(
        'fetch',
        vi.fn(() => {
          if (!resyncArmed) {
            return Promise.resolve(new Response(JSON.stringify([]), { status: 200 }))
          }
          return new Promise<Response>((_resolve, reject) => {
            rejectResync = reject
          })
        }),
      )

      const { result } = renderHook(() => useAlertsSnapshot('/alerts/active', 'active'), {
        wrapper: strictWrapper,
      })
      await waitFor(() => expect(result.current).toEqual({ status: 'loaded', items: [] }))

      vi.useFakeTimers()
      const firstSocket = currentSocket()
      act(() => firstSocket.triggerOpen())
      act(() => firstSocket.triggerClose())
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1000)
      })
      resyncArmed = true
      act(() => currentSocket().triggerOpen())
      vi.useRealTimers()

      sendAlert(alert({ id: 'live-b1', state: 'firing' }))
      act(() => rejectResync?.(new Error('network error')))

      await waitFor(() =>
        expect(result.current).toEqual({ status: 'loaded', items: [alert({ id: 'live-b1', state: 'firing' })] }),
      )
    })
  })
})
