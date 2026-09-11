import { act, render, screen, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { OverviewPage } from './OverviewPage'
import { LiveStreamProvider } from '../hooks/LiveStreamContext'
import { MockWebSocket } from '../test/MockWebSocket'
import type { AlertEvent, Device, SensorHistory } from '../types/domain'

const RACK_A1: Device = {
  deviceId: 'rack-a1',
  name: 'Rack A1',
  kind: 'rack',
  location: 'Server Room / Rack A1',
  channels: [
    { channel: 'exhaust_temp', unit: '°C' },
    { channel: 'power_draw', unit: 'W' },
  ],
}

const RACK_A2: Device = {
  deviceId: 'rack-a2',
  name: 'Rack A2',
  kind: 'rack',
  location: 'Server Room / Rack A2',
  channels: [
    { channel: 'exhaust_temp', unit: '°C' },
    { channel: 'power_draw', unit: 'W' },
  ],
}

const PDU_A1: Device = {
  deviceId: 'pdu-a1',
  name: 'PDU A1',
  kind: 'pdu',
  location: 'Server Room / Rack A1',
  channels: [{ channel: 'power_draw', unit: 'W' }],
}

const UPS_1: Device = {
  deviceId: 'ups-1',
  name: 'UPS 1',
  kind: 'ups',
  location: 'Server Room / Power',
  channels: [{ channel: 'battery_pct', unit: '%' }],
}

const ALL_DEVICES = [RACK_A1, RACK_A2, PDU_A1, UPS_1]

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

function emptyHistory(deviceId: string, channel: string): SensorHistory {
  return { deviceId, channel, unit: 'unit', bucket: '1m', points: [] }
}

interface MockFetchOptions {
  devices?: Device[]
  activeAlerts?: AlertEvent[]
  history?: (deviceId: string, channel: string) => SensorHistory
}

function mockFetch({ devices = ALL_DEVICES, activeAlerts = [], history }: MockFetchOptions) {
  vi.stubGlobal(
    'fetch',
    vi.fn((input: string | URL) => {
      const url = String(input)
      if (url.includes('/alerts/active')) {
        return Promise.resolve(new Response(JSON.stringify(activeAlerts), { status: 200 }))
      }
      if (url.includes('/sensors/history')) {
        const params = new URL(url, 'http://test.local').searchParams
        const deviceId = params.get('deviceId') ?? ''
        const channel = params.get('channel') ?? ''
        const data = history ? history(deviceId, channel) : emptyHistory(deviceId, channel)
        return Promise.resolve(new Response(JSON.stringify(data), { status: 200 }))
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

function sendAlert(payload: AlertEvent) {
  act(() => {
    currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload }))
  })
}

function renderPage() {
  return render(
    <LiveStreamProvider>
      <MemoryRouter>
        <OverviewPage />
      </MemoryRouter>
    </LiveStreamProvider>,
  )
}

beforeEach(() => {
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
  class StubResizeObserver {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  vi.stubGlobal('ResizeObserver', StubResizeObserver)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('OverviewPage status roll-up', () => {
  it('shows ok for every device when there are no active alerts', async () => {
    mockFetch({ devices: [RACK_A1, UPS_1], activeAlerts: [] })
    renderPage()

    const rollup = await screen.findByRole('region', { name: 'Status roll-up' })
    expect(within(rollup).getByText('2')).toBeTruthy()
  })

  it('gives critical precedence over degraded in the tallies', async () => {
    mockFetch({
      devices: [RACK_A1, RACK_A2, UPS_1],
      activeAlerts: [
        alert({ id: 'w1', deviceId: 'rack-a1', severity: 'warning' }),
        alert({ id: 'c1', deviceId: 'rack-a1', severity: 'critical' }),
        alert({ id: 'w2', deviceId: 'rack-a2', severity: 'warning' }),
      ],
    })
    renderPage()

    const rollup = await screen.findByRole('region', { name: 'Status roll-up' })
    const okTile = within(rollup).getByText('ok').closest('div') as HTMLElement
    const degradedTile = within(rollup).getByText('degraded').closest('div') as HTMLElement
    const criticalTile = within(rollup).getByText('critical').closest('div') as HTMLElement
    expect(within(okTile).getByText('1')).toBeTruthy()
    expect(within(degradedTile).getByText('1')).toBeTruthy()
    expect(within(criticalTile).getByText('1')).toBeTruthy()
  })
})

describe('OverviewPage active alerts widget', () => {
  it('orders critical before warning, newest first within severity, and truncates to top 5', async () => {
    const alerts = [
      alert({ id: 'w-old', deviceId: 'rack-a1', severity: 'warning', startedAt: '2026-09-11T07:00:00Z' }),
      alert({ id: 'c-old', deviceId: 'rack-a1', severity: 'critical', startedAt: '2026-09-11T06:00:00Z' }),
      alert({ id: 'w-new', deviceId: 'rack-a2', severity: 'warning', startedAt: '2026-09-11T09:00:00Z' }),
      alert({ id: 'c-new', deviceId: 'rack-a2', severity: 'critical', startedAt: '2026-09-11T08:00:00Z' }),
    ]
    mockFetch({ activeAlerts: alerts })
    renderPage()

    const widget = await screen.findByRole('region', { name: 'Active alerts' })
    const rows = within(widget).getAllByRole('listitem')
    expect(rows).toHaveLength(4)
    expect(rows.map((row) => row.textContent)).toEqual([
      expect.stringContaining('rack-a2'),
      expect.stringContaining('rack-a1'),
      expect.stringContaining('rack-a2'),
      expect.stringContaining('rack-a1'),
    ])
  })

  it('shows an explicit empty state when there are no active alerts', async () => {
    mockFetch({ activeAlerts: [] })
    renderPage()

    const widget = await screen.findByRole('region', { name: 'Active alerts' })
    expect(within(widget).getByText('No active alerts')).toBeTruthy()
  })

  it('links to /alerts', async () => {
    mockFetch({})
    renderPage()

    const widget = await screen.findByRole('region', { name: 'Active alerts' })
    const link = within(widget).getByText('View all')
    expect(link.getAttribute('href')).toBe('/alerts')
  })
})

describe('OverviewPage live alert reaction', () => {
  it('updates the roll-up and device grid on an incoming firing alert', async () => {
    mockFetch({ devices: [RACK_A1], activeAlerts: [] })
    renderPage()
    await screen.findByText('Rack A1')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'c1', deviceId: 'rack-a1', severity: 'critical', state: 'firing' }))

    const rollup = await screen.findByRole('region', { name: 'Status roll-up' })
    const criticalTile = within(rollup).getByText('critical').closest('div') as HTMLElement
    expect(within(criticalTile).getByText('1')).toBeTruthy()

    const grid = screen.getByRole('region', { name: 'Devices' })
    expect(within(grid).getByText('critical')).toBeTruthy()
  })

  it('updates the roll-up and device grid back to ok on resolved', async () => {
    mockFetch({
      devices: [RACK_A1],
      activeAlerts: [alert({ id: 'w1', deviceId: 'rack-a1', severity: 'warning' })],
    })
    renderPage()
    const grid = await screen.findByRole('region', { name: 'Devices' })
    await within(grid).findByText('warning')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'w1', deviceId: 'rack-a1', severity: 'warning', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }))

    await within(grid).findByText('ok')
    const rollup = screen.getByRole('region', { name: 'Status roll-up' })
    const okTile = within(rollup).getByText('ok').closest('div') as HTMLElement
    expect(within(okTile).getByText('1')).toBeTruthy()
  })
})

describe('OverviewPage reconnect resync', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('refetches active alerts (but not the device registry) after reconnect', async () => {
    mockFetch({ devices: [RACK_A1] })
    renderPage()
    await vi.waitFor(() => expect(screen.getByText('Rack A1')).toBeTruthy())

    const countMatching = (pattern: string) =>
      vi.mocked(fetch).mock.calls.filter(([input]) => String(input).includes(pattern)).length

    const activeCallsBefore = countMatching('/alerts/active')
    const deviceCallsBefore = countMatching('/devices')

    const firstSocket = currentSocket()
    firstSocket.triggerOpen()
    firstSocket.triggerClose()
    await vi.advanceTimersByTimeAsync(1000)
    currentSocket().triggerOpen()

    await vi.waitFor(() => expect(countMatching('/alerts/active')).toBe(activeCallsBefore + 1))
    expect(countMatching('/devices')).toBe(deviceCallsBefore)
  })
})

describe('OverviewPage headline metrics', () => {
  it('aggregates the current value across contributing devices via LiveStreamContext', async () => {
    mockFetch({ devices: [RACK_A1, RACK_A2, PDU_A1, UPS_1] })
    renderPage()
    await screen.findByText('Max rack exhaust temperature')
    currentSocket().triggerOpen()

    act(() => {
      currentSocket().triggerMessage(
        JSON.stringify({
          kind: 'reading',
          payload: { deviceId: 'rack-a1', channel: 'exhaust_temp', value: 31.2, unit: '°C', timestamp: 't' },
        }),
      )
      currentSocket().triggerMessage(
        JSON.stringify({
          kind: 'reading',
          payload: { deviceId: 'rack-a2', channel: 'exhaust_temp', value: 33.1, unit: '°C', timestamp: 't' },
        }),
      )
      currentSocket().triggerMessage(
        JSON.stringify({
          kind: 'reading',
          payload: { deviceId: 'rack-a1', channel: 'power_draw', value: 1180, unit: 'W', timestamp: 't' },
        }),
      )
      currentSocket().triggerMessage(
        JSON.stringify({
          kind: 'reading',
          payload: { deviceId: 'rack-a2', channel: 'power_draw', value: 1340, unit: 'W', timestamp: 't' },
        }),
      )
      currentSocket().triggerMessage(
        JSON.stringify({
          kind: 'reading',
          payload: { deviceId: 'pdu-a1', channel: 'power_draw', value: 2360, unit: 'W', timestamp: 't' },
        }),
      )
      currentSocket().triggerMessage(
        JSON.stringify({
          kind: 'reading',
          payload: { deviceId: 'ups-1', channel: 'battery_pct', value: 97, unit: '%', timestamp: 't' },
        }),
      )
    })

    expect(await screen.findByText('33.1 °C')).toBeTruthy()
    expect(await screen.findByText('4880 W')).toBeTruthy()
    expect(await screen.findByText('97 %')).toBeTruthy()
  })

  it('shows an explicit "no live value" state before any reading arrives', async () => {
    mockFetch({ devices: [UPS_1] })
    renderPage()
    await screen.findByText('UPS battery')
    expect(screen.getAllByText('No live value').length).toBeGreaterThan(0)
  })
})

describe('OverviewPage sparklines', () => {
  it('shows a loading state while history is in flight', async () => {
    let resolveHistory: ((value: Response) => void) | undefined
    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = String(input)
        if (url.includes('/sensors/history')) {
          return new Promise<Response>((resolve) => {
            resolveHistory = resolve
          })
        }
        if (url.includes('/alerts/active')) {
          return Promise.resolve(new Response(JSON.stringify([]), { status: 200 }))
        }
        return Promise.resolve(new Response(JSON.stringify([UPS_1]), { status: 200 }))
      }),
    )
    renderPage()

    expect(await screen.findByText('Loading trend…')).toBeTruthy()
    act(() => resolveHistory?.(new Response(JSON.stringify(emptyHistory('ups-1', 'battery_pct')), { status: 200 })))
  })

  it('shows an explicit empty state when history has no points', async () => {
    mockFetch({ devices: [UPS_1], history: (deviceId, channel) => emptyHistory(deviceId, channel) })
    renderPage()

    await screen.findByText('UPS battery')
    expect(await screen.findAllByText('No data for this range.')).not.toHaveLength(0)
  })

  it('shows an explicit error state when a history fetch fails', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = String(input)
        if (url.includes('/sensors/history')) {
          return Promise.resolve(new Response('boom', { status: 500 }))
        }
        if (url.includes('/alerts/active')) {
          return Promise.resolve(new Response(JSON.stringify([]), { status: 200 }))
        }
        return Promise.resolve(new Response(JSON.stringify([UPS_1]), { status: 200 }))
      }),
    )
    renderPage()

    expect(await screen.findByText("Couldn't load trend.")).toBeTruthy()
  })
})

describe('OverviewPage device grid', () => {
  it('links each device tile to its detail route', async () => {
    mockFetch({ devices: [RACK_A1] })
    renderPage()

    const link = (await screen.findByText('Rack A1')).closest('a')
    expect(link?.getAttribute('href')).toBe('/devices/rack-a1')
  })
})
