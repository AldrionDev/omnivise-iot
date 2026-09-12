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
    'flex-1 rounded-sm px-sm py-xs text-center text-sm md:flex-none md:text-left',
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
    <div className="flex min-h-screen min-w-0 flex-col overflow-x-hidden bg-background text-foreground">
      <header className="flex flex-wrap items-center justify-between gap-sm border-b border-border px-md py-sm">
        <span className="text-lg font-semibold">OmniVise IoT</span>
        <div className="flex items-center gap-sm">
          <ConnectionIndicator state={connectionState} />
          <ThemeToggle />
        </div>
      </header>
      <div className="flex min-w-0 flex-1 flex-col md:flex-row">
        <nav aria-label="Primary" className="flex w-full flex-wrap gap-xs border-b border-border p-sm md:w-48 md:flex-col md:border-b-0 md:border-r">
          {NAV_ITEMS.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.end} className={navLinkClassName}>
              {item.label}
            </NavLink>
          ))}
        </nav>
        <main className="min-w-0 flex-1 p-md">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
