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
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('App routing', () => {
  it('renders the Overview placeholder at /', () => {
    renderAt('/')
    expect(screen.getByText('Fleet overview is coming in a later issue.')).toBeTruthy()
  })

  it('renders the Devices placeholder at /devices', () => {
    renderAt('/devices')
    expect(screen.getByText('The device registry view is coming in a later issue.')).toBeTruthy()
  })

  it('renders the Device detail placeholder at /devices/:deviceId', () => {
    renderAt('/devices/rack-a1')
    expect(screen.getByText('Device: rack-a1')).toBeTruthy()
  })

  it('renders the Alerts placeholder at /alerts', () => {
    renderAt('/alerts')
    expect(screen.getByText('The alert history view is coming in a later issue.')).toBeTruthy()
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
