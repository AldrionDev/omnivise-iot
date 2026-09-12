import { createContext, useContext, type ReactNode } from 'react'
import { useLiveStream, type LiveStreamState } from './useLiveStream'

const LiveStreamContext = createContext<LiveStreamState | null>(null)

/**
 * The single useLiveStream call site for the whole app. Mount this once
 * (AppShell does, as a persistent parent route) and read the connection via
 * useLiveStreamContext from anywhere below it -- never call useLiveStream
 * again elsewhere, or a second WebSocket opens.
 */
export function LiveStreamProvider({ children }: { children: ReactNode }) {
  const state = useLiveStream()
  return <LiveStreamContext.Provider value={state}>{children}</LiveStreamContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components -- co-locating the hook keeps provider/context/hook as one small cohesive module
export function useLiveStreamContext(): LiveStreamState {
  const context = useContext(LiveStreamContext)
  if (!context) {
    throw new Error('useLiveStreamContext must be used within a LiveStreamProvider')
  }
  return context
}
