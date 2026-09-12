import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'
import { MockWebSocket } from './test/MockWebSocket'
import { ThemeProvider } from './theme/ThemeProvider'

function renderAt(path: string) {
  return render(
    <ThemeProvider>
      <MemoryRouter initialEntries={[path]}>
        <App />
      </MemoryRouter>
    </ThemeProvider>,
  )
}

beforeEach(() => {
  localStorage.clear()
  document.documentElement.removeAttribute('data-theme')
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
  // Devices/Device detail now fetch real data (#75); a never-resolving fetch
  // keeps their loading state stable for these routing-only assertions
  // without needing to mock full REST responses (covered by their own tests).
  vi.stubGlobal(
    'fetch',
    vi.fn(() => new Promise(() => {})),
  )
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('App routing', () => {
  it('renders the Overview page at /', () => {
    renderAt('/')
    expect(screen.getByText('Loading overview…')).toBeTruthy()
  })

  it('renders the Devices page at /devices', () => {
    renderAt('/devices')
    expect(screen.getByText('Loading devices…')).toBeTruthy()
  })

  it('renders the Device detail page at /devices/:deviceId', () => {
    renderAt('/devices/rack-a1')
    expect(screen.getByText('Loading device…')).toBeTruthy()
  })

  it('renders the Alerts page at /alerts', () => {
    renderAt('/alerts')
    expect(screen.getByText('Loading alerts…')).toBeTruthy()
  })

  it('renders a not-found placeholder for an unknown route', () => {
    renderAt('/something/unknown')
    expect(screen.getByText('Page not found')).toBeTruthy()
  })

  it('renders every route inside the shared AppShell', () => {
    renderAt('/alerts')
    expect(screen.getByRole('link', { name: 'Overview' })).toBeTruthy()
  })
})
