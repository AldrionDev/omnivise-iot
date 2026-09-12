import { act, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MockWebSocket } from '../test/MockWebSocket'
import { ThemeProvider } from '../theme/ThemeProvider'
import { AppShell } from './AppShell'

function renderShell(initialPath: string) {
  return render(
    <ThemeProvider>
      <MemoryRouter initialEntries={[initialPath]}>
        <Routes>
          <Route element={<AppShell />}>
            <Route index element={<div>overview content</div>} />
            <Route path="devices" element={<div>devices content</div>} />
            <Route path="alerts" element={<div>alerts content</div>} />
          </Route>
        </Routes>
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

describe('AppShell', () => {
  it('renders navigation links to the primary routes', () => {
    renderShell('/')
    expect(screen.getByRole('link', { name: 'Overview' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Devices' })).toBeTruthy()
    expect(screen.getByRole('link', { name: 'Alerts' })).toBeTruthy()
  })

  it('uses a stacked, full-width navigation below the desktop sidebar breakpoint', () => {
    renderShell('/')
    const navigation = screen.getByRole('navigation', { name: 'Primary' })
    expect(navigation.className).toContain('w-full')
    expect(navigation.className).toContain('md:w-48')
    expect(navigation.className).toContain('md:border-r')
    expect(navigation.className).toContain('border-b')
    expect(screen.getByRole('link', { name: 'Overview' }).className).toContain('flex-1')
  })

  it('renders the routed child inside the shell via Outlet', () => {
    renderShell('/devices')
    expect(screen.getByText('devices content')).toBeTruthy()
  })

  it('marks the active route with aria-current', () => {
    renderShell('/devices')
    expect(screen.getByRole('link', { name: 'Devices' }).getAttribute('aria-current')).toBe('page')
    expect(screen.getByRole('link', { name: 'Overview' }).getAttribute('aria-current')).toBeNull()
  })

  it('shows a theme toggle', () => {
    renderShell('/')
    expect(screen.getByRole('button', { name: /switch to (light|dark) theme/i })).toBeTruthy()
  })

  it('shows a connection indicator reflecting the live socket state', () => {
    renderShell('/')
    expect(screen.getByText('Connecting')).toBeTruthy()

    act(() => MockWebSocket.instances[0].triggerOpen())

    expect(screen.getByText('Connected')).toBeTruthy()
  })

  it('keeps a single WebSocket open across in-app route navigation', () => {
    renderShell('/')
    expect(MockWebSocket.instances).toHaveLength(1)

    fireEvent.click(screen.getByRole('link', { name: 'Alerts' }))

    expect(screen.getByText('alerts content')).toBeTruthy()
    expect(MockWebSocket.instances).toHaveLength(1)
  })
})
