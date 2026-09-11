import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { StrictMode } from 'react'
import { MemoryRouter, Route, Routes, useNavigate } from 'react-router'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DeviceDetailPage } from './DeviceDetailPage'
import { LiveStreamProvider } from '../hooks/LiveStreamContext'
import { MockWebSocket } from '../test/MockWebSocket'
import type { AlertEvent, AlertRule, Device, SensorHistory } from '../types/domain'

const RACK_A1: Device = {
  deviceId: 'rack-a1',
  name: 'Rack A1',
  kind: 'rack',
  location: 'Server Room / Rack A1',
  channels: [
    { channel: 'intake_temp', unit: '°C' },
    { channel: 'door_contact', unit: 'state' },
  ],
}

function history(channel: string, unit: string): SensorHistory {
  return {
    deviceId: 'rack-a1',
    channel,
    unit,
    bucket: '5m',
    points: [{ t: '2026-09-11T08:00:00Z', avg: 22, min: 21, max: 23 }],
  }
}

class StubResizeObserver {
  private readonly callback: ResizeObserverCallback
  constructor(callback: ResizeObserverCallback) {
    this.callback = callback
  }
  observe() {
    this.callback(
      [{ contentRect: { width: 400, height: 300 } } as ResizeObserverEntry],
      this as unknown as ResizeObserver,
    )
  }
  unobserve() {}
  disconnect() {}
}

interface MockRoutes {
  devices?: Record<string, Device>
  active?: AlertEvent[]
  rules?: AlertRule[]
  alerts?: AlertEvent[]
  history?: Record<string, SensorHistory | Error>
}

function jsonResponse(body: unknown, status = 200) {
  const alerts = Array.isArray(body)
    ? body.filter((item): item is AlertEvent => typeof item === 'object' && item !== null && 'sequence' in item)
    : []
  const watermark = Math.max(0, ...alerts.map((item) => item.sequence))
  return Promise.resolve(new Response(JSON.stringify(body), {
    status,
    headers: { 'X-Alert-Watermark': String(watermark) },
  }))
}

function mockFetch(routes: MockRoutes) {
  vi.stubGlobal(
    'fetch',
    vi.fn((input: string | URL) => {
      const url = new URL(String(input), 'http://test.local')
      const path = url.pathname
      const deviceId = url.searchParams.get('deviceId') ?? undefined

      if (path.startsWith('/devices/')) {
        const id = path.split('/').pop() as string
        const device = routes.devices?.[id]
        if (!device) {
          return jsonResponse({ error: 'device not found', deviceId: id }, 404)
        }
        return jsonResponse(device)
      }
      if (path === '/alerts/active') {
        return jsonResponse(routes.active ?? [])
      }
      if (path === '/alerts/rules') {
        return jsonResponse(routes.rules ?? [])
      }
      if (path === '/alerts') {
        return jsonResponse(routes.alerts ?? [])
      }
      if (path === '/sensors/history') {
        const channel = url.searchParams.get('channel') as string
        const entry = routes.history?.[channel]
        if (entry instanceof Error) {
          return jsonResponse({ error: 'invalid_request', field: 'channel', message: 'boom' }, 500)
        }
        if (entry) {
          return jsonResponse(entry)
        }
        return jsonResponse(history(channel, '?'))
      }
      void deviceId
      throw new Error(`unexpected fetch: ${path}`)
    }),
  )
}

function alertPayload(overrides: Partial<AlertEvent>): AlertEvent {
  return {
    sequence: overrides.state === 'resolved' ? 3 : overrides.severity === 'critical' ? 2 : 1,
    id: 'live-1',
    ruleId: 'rack-intake-temp-high',
    deviceId: 'rack-a1',
    channel: 'intake_temp',
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

function sendAlert(alert: AlertEvent) {
  // Direct subscribers enqueue their pure React updates synchronously; act()
  // flushes those updates before race tests resolve a pending REST snapshot.
  act(() => {
    currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload: alert }))
  })
}

function headerStatus(): HTMLElement {
  return within(document.querySelector('header') as HTMLElement).getByText(/^(ok|warning|critical)$/)
}

async function findHeaderStatus(expected: string) {
  return waitFor(() => {
    const el = headerStatus()
    expect(el.textContent).toBe(expected)
    return el
  })
}

function renderDetail(deviceId = 'rack-a1') {
  return render(
    <LiveStreamProvider>
      <MemoryRouter initialEntries={[`/devices/${deviceId}`]}>
        <Routes>
          <Route path="/devices/:deviceId" element={<DeviceDetailPage />} />
        </Routes>
      </MemoryRouter>
    </LiveStreamProvider>,
  )
}

/**
 * Renders under StrictMode -- required for the issue #75 review finding B1
 * regression tests below, since React only double-invokes setState updater
 * functions (to catch impurity) in development-mode StrictMode.
 */
function renderDetailStrict(deviceId = 'rack-a1') {
  return render(
    <StrictMode>
      <LiveStreamProvider>
        <MemoryRouter initialEntries={[`/devices/${deviceId}`]}>
          <Routes>
            <Route path="/devices/:deviceId" element={<DeviceDetailPage />} />
          </Routes>
        </MemoryRouter>
      </LiveStreamProvider>
    </StrictMode>,
  )
}

beforeEach(() => {
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
  vi.stubGlobal('ResizeObserver', StubResizeObserver)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('DeviceDetailPage', () => {
  it('fetches and renders the device header', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()

    expect(await screen.findByText('Rack A1')).toBeTruthy()
    expect(screen.getByText('Server Room / Rack A1')).toBeTruthy()
  })

  it('shows a not-found state for an unknown device', async () => {
    mockFetch({ devices: {} })
    renderDetail('unknown-device')

    expect(await screen.findByText(/not found/i)).toBeTruthy()
  })
})

describe('DeviceDetailPage history requests', () => {
  it('issues one history request per numeric channel with deviceId/channel/from/to/bucket', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()
    await screen.findByText('Rack A1')

    await screen.findByText('intake_temp')

    const historyCalls = vi
      .mocked(fetch)
      .mock.calls.map(([input]) => String(input))
      .filter((url) => url.includes('/sensors/history'))

    expect(historyCalls).toHaveLength(1)
    const url = new URL(historyCalls[0], 'http://test.local')
    expect(url.searchParams.get('deviceId')).toBe('rack-a1')
    expect(url.searchParams.get('channel')).toBe('intake_temp')
    expect(url.searchParams.get('bucket')).toBe('5m')
    expect(url.searchParams.get('from')).toMatch(/Z$/)
    expect(url.searchParams.get('to')).toMatch(/Z$/)
  })

  it('never fetches history for the non-numeric door_contact channel', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()
    await screen.findByText('door_contact')

    const historyCalls = vi
      .mocked(fetch)
      .mock.calls.map(([input]) => String(input))
      .filter((url) => url.includes('/sensors/history') && url.includes('door_contact'))

    expect(historyCalls).toHaveLength(0)
    expect(screen.getByText('History chart unavailable for non-numeric channel.')).toBeTruthy()
  })

  it('reissues history requests with a shared from/to pair when the range changes', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()
    await screen.findByText('intake_temp')

    vi.mocked(fetch).mockClear()
    fireEvent.click(screen.getByRole('button', { name: '24h' }))

    await waitFor(() => {
      const calls = vi
        .mocked(fetch)
        .mock.calls.map(([input]) => String(input))
        .filter((url) => url.includes('/sensors/history'))
      expect(calls).toHaveLength(1)
    })

    const url = new URL(
      vi
        .mocked(fetch)
        .mock.calls.map(([input]) => String(input))
        .find((u) => u.includes('/sensors/history')) as string,
      'http://test.local',
    )
    expect(url.searchParams.get('bucket')).toBe('1h')
  })

  it('does not blank out a working channel chart when another channel fails', async () => {
    const twoNumericChannelDevice: Device = {
      ...RACK_A1,
      channels: [
        { channel: 'intake_temp', unit: '°C' },
        { channel: 'humidity', unit: '%' },
      ],
    }
    mockFetch({
      devices: { 'rack-a1': twoNumericChannelDevice },
      history: {
        intake_temp: history('intake_temp', '°C'),
        humidity: new Error('boom'),
      },
    })
    renderDetail()
    await screen.findByText('intake_temp')

    expect(await screen.findByText("Couldn't load chart data.")).toBeTruthy()
    await waitFor(() => {
      expect(document.querySelectorAll('svg').length).toBeGreaterThan(0)
    })
  })
})

describe('DeviceDetailPage live current values', () => {
  it('shows "No live value" before any reading has arrived', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()
    await screen.findByText('intake_temp')

    expect(screen.getAllByText('No live value').length).toBeGreaterThan(0)
  })

  it('reads the current value from LiveStreamContext once a reading arrives', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()
    await screen.findByText('intake_temp')

    const socket = MockWebSocket.instances[0]
    socket.triggerOpen()
    socket.triggerMessage(
      JSON.stringify({
        kind: 'reading',
        payload: {
          deviceId: 'rack-a1',
          channel: 'intake_temp',
          value: 22.5,
          unit: '°C',
          timestamp: '2026-09-11T08:00:00Z',
        },
      }),
    )

    expect(await screen.findByText('22.5 °C')).toBeTruthy()
  })

  it('keeps door_contact as the raw open/closed string, never numeric', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()
    await screen.findByText('door_contact')

    const socket = MockWebSocket.instances[0]
    socket.triggerOpen()
    socket.triggerMessage(
      JSON.stringify({
        kind: 'reading',
        payload: {
          deviceId: 'rack-a1',
          channel: 'door_contact',
          value: 'open',
          unit: 'state',
          timestamp: '2026-09-11T08:00:00Z',
        },
      }),
    )

    expect(await screen.findByText('open')).toBeTruthy()
  })

  it('reverts to "No live value" once the WebSocket disconnects and readings are cleared', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 } })
    renderDetail()
    await screen.findByText('intake_temp')

    const socket = MockWebSocket.instances[0]
    socket.triggerOpen()
    socket.triggerMessage(
      JSON.stringify({
        kind: 'reading',
        payload: {
          deviceId: 'rack-a1',
          channel: 'intake_temp',
          value: 22.5,
          unit: '°C',
          timestamp: '2026-09-11T08:00:00Z',
        },
      }),
    )
    await screen.findByText('22.5 °C')

    socket.triggerClose()

    await waitFor(() => {
      expect(screen.queryByText('22.5 °C')).toBeNull()
    })
    expect(screen.getAllByText('No live value').length).toBeGreaterThan(0)
  })
})

describe('DeviceDetailPage rules panel', () => {
  it('renders backend-provided rules as-is without reimplementing matching', async () => {
    mockFetch({
      devices: { 'rack-a1': RACK_A1 },
      rules: [
        {
          ruleId: 'rack-intake-temp-high',
          enabled: true,
          match: { deviceId: null, deviceKind: 'rack', channel: 'intake_temp' },
          operator: '>',
          threshold: 30,
          clearThreshold: 27,
          severity: 'warning',
        },
      ],
    })
    renderDetail()

    expect(await screen.findByText(/rack-intake-temp-high/)).toBeTruthy()
  })

  it('shows an explicit empty state for an empty rules array (e.g. pdu-a1)', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, rules: [] })
    renderDetail()

    expect(await screen.findByText('No alert rules configured for this device.')).toBeTruthy()
  })
})

describe('DeviceDetailPage recent alerts', () => {
  it('fetches recent alerts filtered by deviceId', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, alerts: [] })
    renderDetail()
    await screen.findByText('No recent alerts for this device.')

    const call = vi
      .mocked(fetch)
      .mock.calls.map(([input]) => String(input))
      .find((url) => url.includes('/alerts?') || url.endsWith('/alerts'))
    const url = new URL(call as string, 'http://test.local')
    expect(url.pathname).toBe('/alerts')
    expect(url.searchParams.get('deviceId')).toBe('rack-a1')
  })

  it('renders returned alerts newest-first as provided by the backend', async () => {
    mockFetch({
      devices: { 'rack-a1': RACK_A1 },
      alerts: [
        {
          sequence: 1,
          id: 'a2',
          ruleId: 'r1',
          deviceId: 'rack-a1',
          channel: 'intake_temp',
          severity: 'critical',
          state: 'firing',
          triggeredValue: 32,
          lastValue: 32,
          startedAt: '2026-09-11T09:00:00Z',
          resolvedAt: null,
        },
      ],
    })
    renderDetail()

    expect(await screen.findByText('intake_temp · firing')).toBeTruthy()
    expect(screen.getByText('critical')).toBeTruthy()
  })
})

function NavHelper({ to }: { to: string }) {
  const navigate = useNavigate()
  return (
    <button type="button" onClick={() => navigate(to)}>
      navigate
    </button>
  )
}

describe('DeviceDetailPage live alert reaction', () => {
  it('shows the initial REST recent-alerts snapshot before any WS message', async () => {
    mockFetch({
      devices: { 'rack-a1': RACK_A1 },
      alerts: [alertPayload({ id: 'rest-1', channel: 'intake_temp', state: 'firing' })],
    })
    renderDetail()

    expect(await screen.findByText('intake_temp · firing')).toBeTruthy()
  })

  it('appends an incoming firing WS alert for the current device without a refetch', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, alerts: [] })
    renderDetail()
    await screen.findByText('No recent alerts for this device.')

    const socket = currentSocket()
    socket.triggerOpen()
    const alertCallsBefore = vi.mocked(fetch).mock.calls.filter(
      ([input]) => String(input).includes('/alerts'),
    ).length
    sendAlert(alertPayload({ id: 'live-1', channel: 'intake_temp', state: 'firing' }))

    expect(await screen.findByText('intake_temp · firing')).toBeTruthy()
    expect(vi.mocked(fetch).mock.calls.filter(
      ([input]) => String(input).includes('/alerts'),
    )).toHaveLength(alertCallsBefore)
  })

  it('updates the same row on a resolved transition instead of duplicating it', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, alerts: [] })
    renderDetail()
    await screen.findByText('No recent alerts for this device.')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ id: 'live-1', channel: 'intake_temp', state: 'firing' }))
    await screen.findByText('intake_temp · firing')

    sendAlert(
      alertPayload({
        id: 'live-1',
        channel: 'intake_temp',
        state: 'resolved',
        resolvedAt: '2026-09-11T08:05:00Z',
      }),
    )

    expect(await screen.findByText('intake_temp · resolved')).toBeTruthy()
    expect(screen.queryByText('intake_temp · firing')).toBeNull()
    expect(screen.getAllByText(/intake_temp ·/)).toHaveLength(1)
  })

  it('changes status to critical on an incoming firing critical alert', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, active: [] })
    renderDetail()
    await findHeaderStatus('ok')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ id: 'c1', severity: 'critical', state: 'firing' }))

    await findHeaderStatus('critical')
  })

  it('falls back to warning when the critical alert resolves but a warning remains active', async () => {
    mockFetch({
      devices: { 'rack-a1': RACK_A1 },
      active: [alertPayload({ id: 'w1', severity: 'warning', state: 'firing' })],
    })
    renderDetail()
    await findHeaderStatus('warning')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ id: 'c1', severity: 'critical', state: 'firing' }))
    await findHeaderStatus('critical')

    sendAlert(
      alertPayload({ id: 'c1', severity: 'critical', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }),
    )

    await findHeaderStatus('warning')
  })

  it('returns status to ok once the final firing alert resolves', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, active: [] })
    renderDetail()
    await findHeaderStatus('ok')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ id: 'w1', severity: 'warning', state: 'firing' }))
    await findHeaderStatus('warning')

    sendAlert(
      alertPayload({ id: 'w1', severity: 'warning', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }),
    )

    await findHeaderStatus('ok')
  })

  it('ignores a live alert transition for a different device', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, active: [], alerts: [] })
    renderDetail()
    await screen.findByText('ok')
    await screen.findByText('No recent alerts for this device.')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ id: 'other', deviceId: 'ups-1', severity: 'critical', state: 'firing' }))

    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(screen.getByText('ok')).toBeTruthy()
    expect(screen.getByText('No recent alerts for this device.')).toBeTruthy()
  })

  it('keeps the recent-alerts list newest-first and capped at 20 as live alerts arrive', async () => {
    const initial = Array.from({ length: 20 }, (_, i) =>
      alertPayload({ id: `rest-${i}`, channel: `ch-${i}`, startedAt: '2026-09-11T07:00:00Z' }),
    )
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, alerts: initial })
    renderDetail()
    await screen.findByText('ch-0 · firing')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ sequence: 2, id: 'brand-new', channel: 'humidity', state: 'firing' }))

    expect(await screen.findByText('humidity · firing')).toBeTruthy()
    expect(screen.queryAllByText(/· firing|· resolved/)).toHaveLength(20)
  })
})

describe('DeviceDetailPage reconnect resync', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('refetches active alerts and recent alerts once connected recovers from reconnecting', async () => {
    mockFetch({ devices: { 'rack-a1': RACK_A1 }, active: [], alerts: [] })
    renderDetail()
    await vi.waitFor(() => expect(screen.getByText('ok')).toBeTruthy())

    const firstSocket = currentSocket()
    firstSocket.triggerOpen()

    const countMatching = (pattern: string) =>
      vi.mocked(fetch).mock.calls.filter(([input]) => String(input).includes(pattern)).length

    const activeCallsBefore = countMatching('/alerts/active')
    const recentCallsBefore = countMatching('/alerts?deviceId')

    firstSocket.triggerClose() // -> reconnecting, schedules retry at 1000ms
    await vi.advanceTimersByTimeAsync(1000) // socket #2 created
    currentSocket().triggerOpen() // -> connected again: recovery

    await vi.waitFor(() => {
      expect(countMatching('/alerts/active')).toBe(activeCallsBefore + 1)
      expect(countMatching('/alerts?deviceId')).toBe(recentCallsBefore + 1)
    })
  })
})

describe('DeviceDetailPage snapshot-vs-live-alert race (issue #75 M1)', () => {
  function mockFetchWithDeferredAlerts() {
    let resolveActive: ((value: Response) => void) | undefined
    let resolveRecent: ((value: Response) => void) | undefined
    const activePromise = new Promise<Response>((resolve) => {
      resolveActive = resolve
    })
    const recentPromise = new Promise<Response>((resolve) => {
      resolveRecent = resolve
    })

    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = new URL(String(input), 'http://test.local')
        const path = url.pathname
        if (path.startsWith('/devices/')) {
          return jsonResponse(RACK_A1)
        }
        if (path === '/alerts/rules') {
          return jsonResponse([])
        }
        if (path === '/alerts/active') {
          return activePromise
        }
        if (path === '/alerts') {
          return recentPromise
        }
        if (path === '/sensors/history') {
          const channel = url.searchParams.get('channel') as string
          return jsonResponse(history(channel, '?'))
        }
        throw new Error(`unexpected fetch: ${path}`)
      }),
    )

    return {
      resolveActive: (items: AlertEvent[]) => resolveActive?.(new Response(JSON.stringify(items), { status: 200, headers: { 'X-Alert-Watermark': String(Math.max(0, ...items.map((item) => item.sequence))) } })),
      resolveRecent: (items: AlertEvent[]) => resolveRecent?.(new Response(JSON.stringify(items), { status: 200, headers: { 'X-Alert-Watermark': String(Math.max(0, ...items.map((item) => item.sequence))) } })),
    }
  }

  it('does not lose a firing alert that arrives while the initial snapshot is still loading', async () => {
    const { resolveActive, resolveRecent } = mockFetchWithDeferredAlerts()
    renderDetail()
    await screen.findByText('Rack A1')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ id: 'live-1', severity: 'critical', state: 'firing' }))

    // The REST snapshot was queried before the insert -- it does not contain
    // the alert that already arrived live.
    resolveActive([])
    resolveRecent([])

    await findHeaderStatus('critical')
    expect(await screen.findByText('intake_temp · firing')).toBeTruthy()
  })

  it('replays a firing-then-resolved pair received before the snapshot as one resolved row', async () => {
    const { resolveActive, resolveRecent } = mockFetchWithDeferredAlerts()
    renderDetail()
    await screen.findByText('Rack A1')
    currentSocket().triggerOpen()

    sendAlert(alertPayload({ id: 'live-1', severity: 'warning', state: 'firing' }))
    sendAlert(
      alertPayload({ id: 'live-1', severity: 'warning', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }),
    )

    resolveActive([])
    resolveRecent([])

    await findHeaderStatus('ok')
    expect(await screen.findByText('intake_temp · resolved')).toBeTruthy()
    expect(screen.queryAllByText(/^intake_temp ·/)).toHaveLength(1)
  })

  it('does not duplicate when the snapshot already contains the buffered firing event', async () => {
    const { resolveActive, resolveRecent } = mockFetchWithDeferredAlerts()
    const already = alertPayload({ id: 'live-1', severity: 'critical', state: 'firing' })
    renderDetail()
    await screen.findByText('Rack A1')
    currentSocket().triggerOpen()

    sendAlert(already)
    resolveActive([already])
    resolveRecent([already])

    await findHeaderStatus('critical')
    expect(await screen.findByText('intake_temp · firing')).toBeTruthy()
    expect(screen.queryAllByText(/^intake_temp ·/)).toHaveLength(1)
  })

  it('does not lose a firing alert that arrives while a reconnect resync snapshot is in flight', async () => {
    vi.useFakeTimers()
    try {
      let activeCallCount = 0
      let resolveResyncActive: ((value: Response) => void) | undefined

      vi.stubGlobal(
        'fetch',
        vi.fn((input: string | URL) => {
          const url = new URL(String(input), 'http://test.local')
          const path = url.pathname
          if (path.startsWith('/devices/')) {
            return jsonResponse(RACK_A1)
          }
          if (path === '/alerts/rules' || path === '/alerts') {
            return jsonResponse([])
          }
          if (path === '/alerts/active') {
            activeCallCount += 1
            if (activeCallCount === 1) {
              return jsonResponse([]) // initial load
            }
            return new Promise<Response>((resolve) => {
              resolveResyncActive = resolve
            })
          }
          if (path === '/sensors/history') {
            const channel = url.searchParams.get('channel') as string
            return jsonResponse(history(channel, '?'))
          }
          throw new Error(`unexpected fetch: ${path}`)
        }),
      )

      renderDetail()
      await vi.waitFor(() => expect(headerStatus().textContent).toBe('ok'))

      const firstSocket = currentSocket()
      firstSocket.triggerOpen()
      firstSocket.triggerClose() // -> reconnecting, schedules retry at 1000ms
      await vi.advanceTimersByTimeAsync(1000) // socket #2 created
      currentSocket().triggerOpen() // -> connected: triggers resync

      await vi.waitFor(() => expect(activeCallCount).toBe(2))

      // A brand-new firing alert arrives while the resync request is still
      // pending. activeAlertsInFlightRef is true for the whole resync
      // window (regardless of activeAlerts already being `loaded` from
      // before), so this is buffered, not applied live -- the bug this test
      // targets is the STALE snapshot below overwriting it once replayed.
      sendAlert(alertPayload({ id: 'live-2', severity: 'critical', state: 'firing' }))

      // The stale resync snapshot resolves without it -- it was queried
      // before the alert fired, so it must not wipe out the live update.
      resolveResyncActive?.(new Response(JSON.stringify([]), { status: 200, headers: { 'X-Alert-Watermark': '0' } }))

      // Give the stale response every chance to (incorrectly) win before
      // asserting the final state stays correct.
      await act(async () => {
        await Promise.resolve()
      })
      await vi.waitFor(() => expect(headerStatus().textContent).toBe('critical'))
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('DeviceDetailPage resync failure preserves buffered alerts (issue #75 B1)', () => {
  // Real timers for mount + initial load (StrictMode's extra render pass
  // needs more microtask turns than vi.advanceTimersByTimeAsync(0) flushes
  // reliably); fake timers are switched on only for the reconnect backoff,
  // via triggerReconnectResync below.
  /**
   * Rendered under StrictMode: React only double-invokes a setState updater
   * function (to surface impurity) in development-mode StrictMode. An
   * updater that reads-and-clears a ref is impure -- its first invocation's
   * clear is invisible to the second, whose result React keeps, silently
   * dropping whatever was buffered. This test only catches that class of
   * bug when StrictMode is active; see the mutation-sanity check in the
   * implementation report for confirmation it does.
   */
  function buildRejectingResyncFetch(): {
    armResync: () => void
    resyncRequestCount: () => number
    reject: (reason?: unknown) => void
  } {
    // Driven by an explicit "armed" flag, not a raw call count: StrictMode
    // double-invokes the initial mount's effects (mount -> cleanup -> mount
    // again), so the number of /alerts/active and /alerts calls before the
    // resync is triggered is 2 each, not 1 -- inferring "this is the resync
    // call" from a fixed call-count threshold would be StrictMode-fragile.
    // Both the active-alerts AND recent-alerts resync requests are held
    // pending once armed, so both catch paths are genuinely exercised.
    let resyncArmed = false
    let resyncRequestCount = 0
    let rejectResyncActive: ((reason?: unknown) => void) | undefined
    let rejectResyncRecent: ((reason?: unknown) => void) | undefined

    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = new URL(String(input), 'http://test.local')
        const path = url.pathname
        if (path.startsWith('/devices/')) {
          return jsonResponse(RACK_A1)
        }
        if (path === '/alerts/rules') {
          return jsonResponse([])
        }
        if (path === '/alerts/active') {
          if (!resyncArmed) {
            return jsonResponse([]) // initial load (possibly StrictMode-doubled)
          }
          resyncRequestCount += 1
          return new Promise<Response>((_resolve, reject) => {
            rejectResyncActive = reject
          })
        }
        if (path === '/alerts') {
          if (!resyncArmed) {
            return jsonResponse([]) // initial load (possibly StrictMode-doubled)
          }
          return new Promise<Response>((_resolve, reject) => {
            rejectResyncRecent = reject
          })
        }
        if (path === '/sensors/history') {
          const channel = url.searchParams.get('channel') as string
          return jsonResponse(history(channel, '?'))
        }
        throw new Error(`unexpected fetch: ${path}`)
      }),
    )

    return {
      armResync: () => {
        resyncArmed = true
      },
      resyncRequestCount: () => resyncRequestCount,
      reject: (reason?: unknown) => {
        const error = reason ?? new Error('network error')
        rejectResyncActive?.(error)
        rejectResyncRecent?.(error)
      },
    }
  }

  async function triggerReconnectResync(armResync: () => void) {
    vi.useFakeTimers()
    const firstSocket = currentSocket()
    act(() => firstSocket.triggerOpen())
    act(() => firstSocket.triggerClose()) // -> reconnecting, schedules retry at 1000ms
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000) // socket #2 created
    })
    armResync() // the next /alerts/active call is the resync -- hold it pending
    act(() => currentSocket().triggerOpen()) // -> connected: triggers resync
  }

  it('keeps a firing alert buffered during a resync that then fails', async () => {
    const { armResync, resyncRequestCount, reject } = buildRejectingResyncFetch()

    try {
      renderDetailStrict()
      await waitFor(() => expect(headerStatus().textContent).toBe('ok'))

      await triggerReconnectResync(armResync)
      await vi.waitFor(() => expect(resyncRequestCount()).toBe(1))
      // Real timers from here on: no more backoff scheduling is needed, and
      // vi.waitFor's fake-timer-driven polling does not reliably advance
      // past StrictMode's extra render pass -- plain (real-timer) waitFor
      // does.
      vi.useRealTimers()

      // Arrives while the resync request is still pending -- buffered.
      sendAlert(alertPayload({ id: 'live-b1', severity: 'warning', state: 'firing' }))

      // The resync request fails. The prior loaded (empty) snapshot must be
      // kept and the buffered transition replayed onto it -- not discarded.
      reject()

      await act(async () => {
        await Promise.resolve()
      })
      await waitFor(() => expect(headerStatus().textContent).toBe('warning'))
      expect(await screen.findByText('intake_temp · firing')).toBeTruthy()
    } finally {
      vi.useRealTimers()
    }
  })

  it('replays a firing-then-resolved pair in order onto the prior state when the resync fails', async () => {
    const { armResync, resyncRequestCount, reject } = buildRejectingResyncFetch()

    try {
      renderDetailStrict()
      await waitFor(() => expect(headerStatus().textContent).toBe('ok'))

      await triggerReconnectResync(armResync)
      await vi.waitFor(() => expect(resyncRequestCount()).toBe(1))
      vi.useRealTimers() // see the previous test for why

      sendAlert(alertPayload({ id: 'live-b2', severity: 'critical', state: 'firing' }))
      sendAlert(
        alertPayload({
          id: 'live-b2',
          severity: 'critical',
          state: 'resolved',
          resolvedAt: '2026-09-11T08:05:00Z',
        }),
      )

      reject()

      await act(async () => {
        await Promise.resolve()
      })
      await waitFor(() => expect(headerStatus().textContent).toBe('ok'))
      expect(await screen.findByText('intake_temp · resolved')).toBeTruthy()
      expect(screen.queryAllByText(/^intake_temp ·/)).toHaveLength(1)
    } finally {
      vi.useRealTimers()
    }
  })
})

describe('DeviceDetailPage stale response protection', () => {
  it('ignores a slower response after a fast deviceId change', async () => {
    const RACK_A2: Device = { ...RACK_A1, deviceId: 'rack-a2', name: 'Rack A2' }
    let resolveFirst: ((value: Response) => void) | undefined
    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = new URL(String(input), 'http://test.local')
        if (url.pathname === '/devices/rack-a1') {
          return new Promise<Response>((resolve) => {
            resolveFirst = resolve
          })
        }
        if (url.pathname === '/devices/rack-a2') {
          return jsonResponse(RACK_A2)
        }
        return jsonResponse([])
      }),
    )

    render(
      <LiveStreamProvider>
        <MemoryRouter initialEntries={['/devices/rack-a1']}>
          <NavHelper to="/devices/rack-a2" />
          <Routes>
            <Route path="/devices/:deviceId" element={<DeviceDetailPage />} />
          </Routes>
        </MemoryRouter>
      </LiveStreamProvider>,
    )

    fireEvent.click(screen.getByText('navigate'))

    expect(await screen.findByText('Rack A2')).toBeTruthy()

    resolveFirst?.(new Response(JSON.stringify(RACK_A1), { status: 200 }))
    await Promise.resolve()
    await Promise.resolve()

    expect(screen.getByText('Rack A2')).toBeTruthy()
    expect(screen.queryByText('Rack A1')).toBeNull()
  })
})
