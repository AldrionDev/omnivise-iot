import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { StrictMode } from 'react'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DevicesPage } from './DevicesPage'
import { LiveStreamProvider } from '../hooks/LiveStreamContext'
import { MockWebSocket } from '../test/MockWebSocket'
import type { AlertEvent, Device } from '../types/domain'

const RACK_A1: Device = {
  deviceId: 'rack-a1',
  name: 'Rack A1',
  kind: 'rack',
  location: 'Server Room / Rack A1',
  channels: [{ channel: 'intake_temp', unit: '°C' }],
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
    id: 'a1',
    ruleId: 'r1',
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

function mockFetchJson(devices: Device[], activeAlerts: AlertEvent[]) {
  vi.stubGlobal(
    'fetch',
    vi.fn((input: string | URL) => {
      const url = String(input)
      if (url.includes('/alerts/active')) {
        return Promise.resolve(new Response(JSON.stringify(activeAlerts), { status: 200 }))
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
  // act()-wrapped so the update is flushed synchronously -- required for
  // deterministic race tests against an in-flight REST snapshot fetch.
  act(() => {
    currentSocket().triggerMessage(JSON.stringify({ kind: 'alert', payload }))
  })
}

function renderPage() {
  return render(
    <LiveStreamProvider>
      <MemoryRouter>
        <DevicesPage />
      </MemoryRouter>
    </LiveStreamProvider>,
  )
}

/**
 * Renders under StrictMode -- required for the issue #75 review finding B1
 * regression test below, since React only double-invokes setState updater
 * functions (to catch impurity) in development-mode StrictMode.
 */
function renderPageStrict() {
  return render(
    <StrictMode>
      <LiveStreamProvider>
        <MemoryRouter>
          <DevicesPage />
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

describe('DevicesPage', () => {
  beforeEach(() => {
    mockFetchJson([RACK_A1, UPS_1], [])
  })

  it('loads devices and renders each device name', async () => {
    renderPage()
    expect(await screen.findByText('Rack A1')).toBeTruthy()
    expect(screen.getByText('UPS 1')).toBeTruthy()
  })
})

describe('DevicesPage status derivation', () => {
  it('shows ok for a device with no active alerts', async () => {
    mockFetchJson([RACK_A1], [])
    renderPage()
    expect(await screen.findByText('ok')).toBeTruthy()
  })

  it('shows warning for a device with an active warning alert', async () => {
    mockFetchJson([RACK_A1], [alert({ deviceId: 'rack-a1', severity: 'warning' })])
    renderPage()
    expect(await screen.findByText('warning')).toBeTruthy()
  })

  it('shows critical for a device with an active critical alert', async () => {
    mockFetchJson([RACK_A1], [alert({ deviceId: 'rack-a1', severity: 'critical' })])
    renderPage()
    expect(await screen.findByText('critical')).toBeTruthy()
  })

  it('prefers critical over warning when both apply to the device', async () => {
    mockFetchJson(
      [RACK_A1],
      [
        alert({ deviceId: 'rack-a1', severity: 'warning' }),
        alert({ deviceId: 'rack-a1', severity: 'critical' }),
      ],
    )
    renderPage()
    expect(await screen.findByText('critical')).toBeTruthy()
    expect(screen.queryByText('warning')).toBeNull()
  })
})

describe('DevicesPage filters', () => {
  beforeEach(() => {
    mockFetchJson([RACK_A1, UPS_1], [])
  })

  it('filters by kind', async () => {
    renderPage()
    await screen.findByText('Rack A1')

    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'ups' } })

    expect(screen.queryByText('Rack A1')).toBeNull()
    expect(screen.getByText('UPS 1')).toBeTruthy()
  })

  it('filters by location', async () => {
    renderPage()
    await screen.findByText('Rack A1')

    fireEvent.change(screen.getByLabelText('Location'), {
      target: { value: 'Server Room / Power' },
    })

    expect(screen.queryByText('Rack A1')).toBeNull()
    expect(screen.getByText('UPS 1')).toBeTruthy()
  })

  it('filters by status', async () => {
    mockFetchJson([RACK_A1, UPS_1], [alert({ deviceId: 'rack-a1', severity: 'critical' })])
    renderPage()
    await screen.findByText('Rack A1')

    fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'critical' } })

    expect(screen.getByText('Rack A1')).toBeTruthy()
    expect(screen.queryByText('UPS 1')).toBeNull()
  })

  it('combines kind, location, and status filters', async () => {
    mockFetchJson([RACK_A1, UPS_1], [alert({ deviceId: 'rack-a1', severity: 'critical' })])
    renderPage()
    await screen.findByText('Rack A1')

    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'rack' } })
    fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'critical' } })

    expect(screen.getByText('Rack A1')).toBeTruthy()
    expect(screen.queryByText('UPS 1')).toBeNull()
  })

  it('shows an explicit empty state when filters match nothing', async () => {
    renderPage()
    await screen.findByText('Rack A1')

    fireEvent.change(screen.getByLabelText('Kind'), { target: { value: 'crac' } })

    expect(await screen.findByText('No matching devices')).toBeTruthy()
  })
})

describe('DevicesPage empty registry', () => {
  it('shows an explicit empty state when the registry itself is empty', async () => {
    mockFetchJson([], [])
    renderPage()
    expect(await screen.findByText('No devices')).toBeTruthy()
  })
})

describe('DevicesPage error state', () => {
  it('shows a retryable error state when the initial load fails', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(() => Promise.resolve(new Response('boom', { status: 500 }))),
    )
    renderPage()

    expect(await screen.findByText("Couldn't load devices")).toBeTruthy()

    mockFetchJson([RACK_A1], [])
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))

    expect(await screen.findByText('Rack A1')).toBeTruthy()
  })
})

describe('DevicesPage navigation', () => {
  it('links each row to its device detail route', async () => {
    mockFetchJson([RACK_A1], [])
    renderPage()
    const link = (await screen.findByText('Rack A1')).closest('a')
    expect(link?.getAttribute('href')).toBe('/devices/rack-a1')
  })
})

describe('DevicesPage live alert reaction', () => {
  it('updates the affected device status live on an incoming firing alert', async () => {
    mockFetchJson([RACK_A1, UPS_1], [])
    renderPage()
    await screen.findByText('Rack A1')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'c1', deviceId: 'rack-a1', severity: 'critical', state: 'firing' }))

    expect(await screen.findByText('critical')).toBeTruthy()
  })

  it('prefers critical over warning when a critical alert arrives for an already-warning device', async () => {
    mockFetchJson([RACK_A1], [alert({ id: 'w1', deviceId: 'rack-a1', severity: 'warning' })])
    renderPage()
    await screen.findByText('warning')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'c1', deviceId: 'rack-a1', severity: 'critical', state: 'firing' }))

    expect(await screen.findByText('critical')).toBeTruthy()
    expect(screen.queryByText('warning')).toBeNull()
  })

  it('returns the device to ok once its active alert resolves', async () => {
    mockFetchJson([RACK_A1], [alert({ id: 'w1', deviceId: 'rack-a1', severity: 'warning' })])
    renderPage()
    await screen.findByText('warning')
    currentSocket().triggerOpen()

    sendAlert(
      alert({ id: 'w1', deviceId: 'rack-a1', severity: 'warning', state: 'resolved', resolvedAt: '2026-09-11T08:05:00Z' }),
    )

    expect(await screen.findByText('ok')).toBeTruthy()
  })

  it('only affects the device named by the incoming alert', async () => {
    mockFetchJson([RACK_A1, UPS_1], [])
    renderPage()
    await screen.findByText('Rack A1')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'c1', deviceId: 'ups-1', severity: 'critical', state: 'firing' }))

    await screen.findByText('critical')
    const rackRow = screen.getByText('Rack A1').closest('li') as HTMLElement
    expect(within(rackRow).getByText('ok')).toBeTruthy()
  })
})

describe('DevicesPage reconnect resync', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('refetches active alerts (but not the device registry) after reconnect', async () => {
    mockFetchJson([RACK_A1], [])
    renderPage()
    await vi.waitFor(() => expect(screen.getByText('ok')).toBeTruthy())

    const firstSocket = currentSocket()
    firstSocket.triggerOpen()

    const countMatching = (pattern: string) =>
      vi.mocked(fetch).mock.calls.filter(([input]) => String(input).includes(pattern)).length

    const activeCallsBefore = countMatching('/alerts/active')
    const deviceCallsBefore = countMatching('/devices')

    firstSocket.triggerClose()
    await vi.advanceTimersByTimeAsync(1000)
    currentSocket().triggerOpen()

    await vi.waitFor(() => {
      expect(countMatching('/alerts/active')).toBe(activeCallsBefore + 1)
    })
    expect(countMatching('/devices')).toBe(deviceCallsBefore)
  })
})

describe('DevicesPage snapshot-vs-live-alert race (issue #75 M1)', () => {
  function mockFetchWithDeferredActive(devices: Device[]) {
    let resolveActive: ((value: Response) => void) | undefined
    const activePromise = new Promise<Response>((resolve) => {
      resolveActive = resolve
    })

    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = String(input)
        if (url.includes('/alerts/active')) {
          return activePromise
        }
        if (url.includes('/devices')) {
          return Promise.resolve(new Response(JSON.stringify(devices), { status: 200 }))
        }
        throw new Error(`unexpected fetch: ${url}`)
      }),
    )

    return {
      resolveActive: (items: AlertEvent[]) =>
        resolveActive?.(new Response(JSON.stringify(items), { status: 200 })),
    }
  }

  it('does not lose a firing alert that arrives while the initial active-alert snapshot is loading', async () => {
    const { resolveActive } = mockFetchWithDeferredActive([RACK_A1])
    renderPage()
    await screen.findByText('Loading devices…')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'live-1', deviceId: 'rack-a1', severity: 'critical', state: 'firing' }))

    // The snapshot was queried before the insert -- it does not contain it.
    resolveActive([])

    expect(await screen.findByText('critical')).toBeTruthy()
  })

  it('preserves buffered-transition order: a resolved id must not mask a later distinct firing id', async () => {
    // If the buffered transitions were dropped entirely (rather than
    // replayed in order), the snapshot alone (`[]`) would yield "ok" too --
    // that would be a false pass. live-1 is critical and live-2 is warning:
    // if replay ran out of order (or the resolved transition were applied
    // before the firing one, e.g. a reversed buffer), live-1 would leak back
    // in as active and the status would read "critical" instead of the
    // correct "warning".
    const { resolveActive } = mockFetchWithDeferredActive([RACK_A1])
    renderPage()
    await screen.findByText('Loading devices…')
    currentSocket().triggerOpen()

    sendAlert(alert({ id: 'live-1', deviceId: 'rack-a1', severity: 'critical', state: 'firing' }))
    sendAlert(
      alert({
        id: 'live-1',
        deviceId: 'rack-a1',
        severity: 'critical',
        state: 'resolved',
        resolvedAt: '2026-09-11T08:05:00Z',
      }),
    )
    sendAlert(alert({ id: 'live-2', deviceId: 'rack-a1', severity: 'warning', state: 'firing' }))

    resolveActive([])

    expect(await screen.findByText('warning')).toBeTruthy()
    expect(screen.queryByText('critical')).toBeNull()
  })
})

describe('DevicesPage resync failure preserves buffered alerts (issue #75 B1)', () => {
  // Real timers for mount + initial load (StrictMode's extra render pass
  // needs more microtask turns than fake-timer-driven waiting reliably
  // flushes); fake timers are switched on only for the reconnect backoff.

  function buildRejectingResyncFetch(devices: Device[]): {
    armResync: () => void
    resyncRequestCount: () => number
    reject: (reason?: unknown) => void
  } {
    // See DeviceDetailPage's equivalent helper for why this is driven by an
    // explicit "armed" flag rather than a raw call count.
    let resyncArmed = false
    let resyncRequestCount = 0
    let rejectResyncActive: ((reason?: unknown) => void) | undefined

    vi.stubGlobal(
      'fetch',
      vi.fn((input: string | URL) => {
        const url = String(input)
        if (url.includes('/alerts/active')) {
          if (!resyncArmed) {
            return Promise.resolve(new Response(JSON.stringify([]), { status: 200 }))
          }
          resyncRequestCount += 1
          return new Promise<Response>((_resolve, reject) => {
            rejectResyncActive = reject
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
      reject: (reason?: unknown) => rejectResyncActive?.(reason ?? new Error('network error')),
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

  it(
    /**
     * Rendered under StrictMode: React only double-invokes a setState
     * updater function (to surface impurity) in development-mode
     * StrictMode. An updater that reads-and-clears a ref is impure -- its
     * first invocation's clear is invisible to the second, whose result
     * React keeps, silently dropping whatever was buffered.
     */
    'keeps a firing alert reflected in device status during a resync that then fails',
    async () => {
      const { armResync, resyncRequestCount, reject } = buildRejectingResyncFetch([RACK_A1])

      try {
        renderPageStrict()
        await waitFor(() => expect(screen.getByText('ok')).toBeTruthy())

        await triggerReconnectResync(armResync)
        await vi.waitFor(() => expect(resyncRequestCount()).toBe(1))
        // Real timers from here: no more backoff scheduling needed, and
        // fake-timer-driven waitFor does not reliably advance past
        // StrictMode's extra render pass.
        vi.useRealTimers()

        // Arrives while the resync request is still pending -- buffered.
        sendAlert(alert({ id: 'live-b1', deviceId: 'rack-a1', severity: 'warning', state: 'firing' }))

        // The resync request fails. The prior loaded (empty) snapshot must
        // be kept and the buffered transition replayed onto it.
        reject()

        await act(async () => {
          await Promise.resolve()
        })
        expect(await screen.findByText('warning')).toBeTruthy()
      } finally {
        vi.useRealTimers()
      }
    },
  )
})
