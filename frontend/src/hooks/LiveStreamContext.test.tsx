import { render, renderHook, screen } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MockWebSocket } from '../test/MockWebSocket'
import { LiveStreamProvider, useLiveStreamContext } from './LiveStreamContext'

beforeEach(() => {
  MockWebSocket.reset()
  vi.stubGlobal('WebSocket', MockWebSocket)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

function Consumer() {
  const { connectionState } = useLiveStreamContext()
  return <span>{connectionState}</span>
}

describe('LiveStreamContext', () => {
  it('provides the useLiveStream state to descendants', () => {
    render(
      <LiveStreamProvider>
        <Consumer />
      </LiveStreamProvider>,
    )

    expect(screen.getByText('connecting')).toBeTruthy()
  })

  it('opens exactly one socket even when used through the provider', () => {
    render(
      <LiveStreamProvider>
        <Consumer />
      </LiveStreamProvider>,
    )

    expect(MockWebSocket.instances).toHaveLength(1)
  })

  it('throws a clear error when used outside a provider', () => {
    const { result } = renderHook(() => {
      try {
        return useLiveStreamContext()
      } catch (error) {
        return error
      }
    })

    expect(result.current).toBeInstanceOf(Error)
  })
})
