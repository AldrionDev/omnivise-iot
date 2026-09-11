import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { StrictMode } from 'react'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { AlertsPage } from './AlertsPage'
import { LiveStreamProvider } from '../hooks/LiveStreamContext'
import { MockWebSocket } from '../test/MockWebSocket'
import type { AlertEvent, Device } from '../types/domain'

const RACK_A1: Device = {
  deviceId: 'rack-a1',
  name: 'Rack A1',
  kind: 'rack',
  location: 'Server Room / Rack A1',
  channels: [{ channel: 'exhaust_temp', unit: '°C' }],
}

const UPS_1: Device = {
  deviceId: 'ups-1',
  name: 'UPS 1',
  kind: 'ups',
  location: 'Server Room / Power',
  channels: [{ channel: 'battery_pct', unit: '%' }],
}

function alert(overrides: Partial<AlertEvent>): AlertEvent {
  return {
    sequence: overrides.state === 'resolved' ? 3 : overrides.severity === 'critical' ? 2 : 1,
    id: 'a1',
    ruleId: 'rack-high-temp',
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

function alertResponse(items: AlertEvent[]) {
  const watermark = Math.max(0, ...items.map((item) => item.sequence))
  return new Response(JSON.stringify(items), { status: 200, headers: { 'X-Alert-Watermark': String(watermark) } })
}

function mockFetchJson(alerts: AlertEvent[], devices: Device[] = [RACK_A1, UPS_1]) {
  vi.stubGlobal(
    'fetch',
    vi.fn((input: string | URL) => {
      const url = String(input)
      if (url.includes('/alerts')) {
        return Promise.resolve(alertResponse(alerts))
      }
      if (url.includes('/devices')) {
        return Promise.resolve(new Response(JSON.stringify(devices), { status: 200 }))
      }
      throw new Error(`unexpected fetch: ${url}`)
    }),
  )
}

function currentSocket(): MockWebSocket {
  const socket = MockWebSocket.instances.at(-1)
  if (!socket) {
    throw new Error('no MockWebSocket instance was created')
  }
  return socket
}

/** Alert rows only -- text queries against the whole document can also match
 * a device Select's <option>, which shares the device's plain name. */
function rows() {
  return within(screen.getByRole('list'))
}

function sendAlert(payload: AlertEvent) {
  act(() => {
    currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload }))
  })
}

function renderPage() {
  return render(
    <LiveStreamProvider>
      <MemoryRouter>
        <AlertsPage />
      </MemoryRouter>
    </LiveStreamProvider>,
  )
}

function renderPageStrict() {
  return render(
    <StrictMode>
      <LiveStreamProvider>
        <MemoryRouter>
          <AlertsPage />
        </MemoryRouter>
      </LiveStreamProvider>
    </StrictMode>,
  )
}

beforeEach(() => {
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('AlertsPage initial rendering', () => {
  it('renders every alert from GET /api/alerts', async () => {
    mockFetchJson([
      alert({ id: 'a1', deviceId: 'rack-a1', channel: 'exhaust_temp' }),
      alert({ id: 'a2', deviceId: 'ups-1', channel: 'battery_pct', severity: 'critical' }),
    ])
    renderPage()

    expect(await screen.findByText(/Rack A1.*exhaust_temp/)).toBeTruthy()
    expect(rows().getByText(/UPS 1.*battery_pct/)).toBeTruthy()
  })

  it('shows an explicit empty state when there are no alerts', async () => {
    mockFetchJson([])
    renderPage()
    expect(await screen.findByText('No matching alerts')).toBeTruthy()
  })

  it('shows a retryable-free explicit error state when the initial load fails', async () => {
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response('boom', { status: 500 }))))
    renderPage()
    expect(await screen.findByText("Couldn't load alerts")).toBeTruthy()
  })
})

describe('AlertsPage filters', () => {
  beforeEach(() => {
    mockFetchJson([
      alert({ id: 'a1', deviceId: 'rack-a1', channel: 'exhaust_temp', severity: 'warning', state: 'firing' }),
      alert({ id: 'a2', deviceId: 'ups-1', channel: 'battery_pct', severity: 'critical', state: 'resolved', resolvedAt: '2026-09-11T09:00:00Z' }),
    ])
  })

  it('filters by state', async () => {
    renderPage()
    await screen.findByRole('list')

    fireEvent.change(screen.getByLabelText('State'), { target: { value: 'resolved' } })

    expect(rows().queryByText(/Rack A1/)).toBeNull()
    expect(rows().getByText(/UPS 1/)).toBeTruthy()
  })

  it('filters by severity', async () => {
    renderPage()
    await screen.findByRole('list')

    fireEvent.change(screen.getByLabelText('Severity'), { target: { value: 'critical' } })

    expect(rows().queryByText(/Rack A1/)).toBeNull()
    expect(rows().getByText(/UPS 1/)).toBeTruthy()
  })

  it('filters by device', async () => {
    renderPage()
    await screen.findByRole('list')

    fireEvent.change(screen.getByLabelText('Device'), { target: { value: 'ups-1' } })

    expect(rows().queryByText(/Rack A1/)).toBeNull()
    expect(rows().getByText(/UPS 1/)).toBeTruthy()
  })

  it('combines state, severity, and device filters', async () => {
    renderPage()
    await screen.findByRole('list')

    fireEvent.change(screen.getByLabelText('State'), { target: { value: 'resolved' } })
    fireEvent.change(screen.getByLabelText('Severity'), { target: { value: 'critical' } })
    fireEvent.change(screen.getByLabelText('Device'), { target: { value: 'ups-1' } })

    expect(rows().getByText(/UPS 1/)).toBeTruthy()
    expect(rows().queryByText(/Rack A1/)).toBeNull()
  })

  it('shows an explicit empty state when filters match nothing', async () => {
    renderPage()
    await screen.findByRole('list')

    fireEvent.change(screen.getByLabelText('Device'), { target: { value: 'ups-1' } })
    fireEvent.change(screen.getByLabelText('Severity'), { target: { value: 'warning' } })

    expect(await screen.findByText('No matching alerts')).toBeTruthy()
  })
})

describe('AlertsPage live updates', () => {
  it('prepends a genuinely new firing alert', async () => {
    mockFetchJson([alert({ id: 'old', deviceId: 'rack-a1' })])
    renderPage()
    await screen.findByRole('list')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'new', deviceId: 'ups-1', channel: 'battery_pct', severity: 'critical', state: 'firing' }))

    await waitFor(() => expect(rows().getAllByRole('listitem')).toHaveLength(2))
    const items = rows().getAllByRole('listitem')
    expect(items[0].textContent).toContain('UPS 1')
  })

  it('updates the same row by id on resolved, without duplicating it', async () => {
    mockFetchJson([alert({ id: 'a1', deviceId: 'rack-a1', state: 'firing' })])
    renderPage()
    await screen.findByRole('list')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'a1', deviceId: 'rack-a1', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }))

    await waitFor(() => expect(rows().getAllByRole('listitem')).toHaveLength(1))
    expect(rows().getByText(/resolved/)).toBeTruthy()
  })

  it('preserves other existing rows when one alert updates', async () => {
    mockFetchJson([
      alert({ id: 'a1', deviceId: 'rack-a1' }),
      alert({ id: 'a2', deviceId: 'ups-1', channel: 'battery_pct' }),
    ])
    renderPage()
    await screen.findByRole('list')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'a1', deviceId: 'rack-a1', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }))

    await waitFor(() => expect(rows().getByText(/UPS 1/)).toBeTruthy())
    expect(rows().getAllByRole('listitem')).toHaveLength(2)
  })
})

describe('AlertsPage reconnect resync', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('refetches GET /api/alerts after reconnect', async () => {
    mockFetchJson([alert({ id: 'a1', deviceId: 'rack-a1' })])
    renderPage()
    await vi.waitFor(() => expect(screen.getByRole('list')).toBeTruthy())

    const countMatching = (pattern: string) =>
      vi.mocked(fetch).mock.calls.filter(([input]) => String(input).includes(pattern)).length

    const alertsCallsBefore = countMatching('/alerts?limit=')

    const firstSocket = currentSocket()
    firstSocket.triggerOpen()
    firstSocket.triggerClose()
    await vi.advanceTimersByTimeAsync(1000)
    currentSocket().triggerOpen()

    await vi.waitFor(() => expect(countMatching('/alerts?limit=')).toBe(alertsCallsBefore + 1))
  })
})

describe('AlertsPage snapshot-vs-live-alert race', () => {
  function mockFetchWithDeferredAlerts(devices: Device[]) {
    let resolveAlerts: ((value: Response) => void) | undefined
    const alertsPromise = new Promise<Response>((resolve) => {
      resolveAlerts = resolve
    })

    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = String(input)
        if (url.includes('/alerts?limit=')) {
          return alertsPromise
        }
        if (url.includes('/devices')) {
          return Promise.resolve(new Response(JSON.stringify(devices), { status: 200 }))
        }
        throw new Error(`unexpected fetch: ${url}`)
      }),
    )

    return {
      resolveAlerts: (items: AlertEvent[]) => resolveAlerts?.(alertResponse(items)),
    }
  }

  it('does not drop a live firing alert that arrives while the REST snapshot is pending', async () => {
    const { resolveAlerts } = mockFetchWithDeferredAlerts([RACK_A1, UPS_1])
    renderPage()
    await screen.findByText('Loading alerts…')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'live-1', deviceId: 'rack-a1', severity: 'critical', state: 'firing' }))

    // The stale snapshot was queried before the live insert -- it must not
    // overwrite/drop the buffered transition once it resolves.
    resolveAlerts([])

    await screen.findByRole('list')
    expect(rows().getByText(/Rack A1/)).toBeTruthy()
  })
})

describe('AlertsPage resync failure preserves buffered alerts under StrictMode', () => {
  function buildRejectingResyncFetch(devices: Device[]) {
    let resyncArmed = false
    let resyncRequestCount = 0
    let rejectResync: ((reason?: unknown) => void) | undefined

    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = String(input)
        if (url.includes('/alerts?limit=')) {
          if (!resyncArmed) {
            return Promise.resolve(alertResponse([]))
          }
          resyncRequestCount += 1
          return new Promise<Response>((_resolve, reject) => {
            rejectResync = reject
          })
        }
        if (url.includes('/devices')) {
          return Promise.resolve(new Response(JSON.stringify(devices), { status: 200 }))
        }
        throw new Error(`unexpected fetch: ${url}`)
      }),
    )

    return {
      armResync: () => {
        resyncArmed = true
      },
      resyncRequestCount: () => resyncRequestCount,
      reject: (reason?: unknown) => rejectResync?.(reason ?? new Error('network error')),
    }
  }

  async function triggerReconnectResync(armResync: () => void) {
    vi.useFakeTimers()
    const firstSocket = currentSocket()
    act(() => firstSocket.triggerOpen())
    act(() => firstSocket.triggerClose())
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })
    armResync()
    act(() => currentSocket().triggerOpen())
  }

  it('keeps a firing alert reflected through a resync that then fails', async () => {
    const { armResync, resyncRequestCount, reject } = buildRejectingResyncFetch([RACK_A1])

    try {
      renderPageStrict()
      await waitFor(() => expect(screen.getByText('No matching alerts')).toBeTruthy())

      await triggerReconnectResync(armResync)
      await vi.waitFor(() => expect(resyncRequestCount()).toBe(1))
      vi.useRealTimers()

      sendAlert(alert({ id: 'live-b1', deviceId: 'rack-a1', severity: 'warning', state: 'firing' }))

      reject()

      await act(async () => {
        await Promise.resolve()
      })
      await screen.findByRole('list')
      expect(rows().getByText(/Rack A1/)).toBeTruthy()
    } finally {
      vi.useRealTimers()
    }
  })
})
