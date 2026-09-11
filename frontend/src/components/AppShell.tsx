import { NavLink, Outlet } from 'react-router'
import { LiveStreamProvider, useLiveStreamContext } from '../hooks/LiveStreamContext'
import { cn } from '../lib/cn'
import { ConnectionIndicator } from './ConnectionIndicator'
import { ThemeToggle } from './ThemeToggle'

const NAV_ITEMS = [
  { to: '/', label: 'Overview', end: true },
  { to: '/devices', label: 'Devices', end: false },
  { to: '/alerts', label: 'Alerts', end: false },
] as const

function navLinkClassName({ isActive }: { isActive: boolean }) {
  return cn(
    'rounded-sm px-sm py-xs text-sm',
    isActive ? 'bg-surface-raised text-accent' : 'text-muted hover:text-foreground',
  )
}

/**
 * The one useLiveStream call site for the whole app: AppShell is a pathless
 * parent route, so it (and the LiveStreamProvider it renders) stays mounted
 * across in-app navigation between its child routes -- exactly one socket
 * for the app's lifetime.
 */
export function AppShell() {
  return (
    <LiveStreamProvider>
      <AppShellLayout />
    </LiveStreamProvider>
  )
}

function AppShellLayout() {
  const { connectionState } = useLiveStreamContext()

  return (
    <div className="flex min-h-screen flex-col bg-background text-foreground">
      <header className="flex items-center justify-between border-b border-border px-md py-sm">
        <span className="text-lg font-semibold">OmniVise IoT</span>
        <div className="flex items-center gap-sm">
          <ConnectionIndicator state={connectionState} />
          <ThemeToggle />
        </div>
      </header>
      <div className="flex flex-1">
        <nav aria-label="Primary" className="flex w-48 flex-col gap-xs border-r border-border p-sm">
          {NAV_ITEMS.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.end} className={navLinkClassName}>
              {item.label}
            </NavLink>
          ))}
        </nav>
        <main className="flex-1 p-md">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
