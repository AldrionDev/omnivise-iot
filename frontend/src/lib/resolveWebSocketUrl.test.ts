import { describe, expect, it } from 'vitest'
import { resolveWebSocketUrl } from './resolveWebSocketUrl'

describe('resolveWebSocketUrl', () => {
  it.each([
    ['http:', 'example.test', 'ws://example.test/ws/sensors'],
    ['https:', 'example.test', 'wss://example.test/ws/sensors'],
    ['http:', 'example.test:3000', 'ws://example.test:3000/ws/sensors'],
    ['https:', 'example.test:8443', 'wss://example.test:8443/ws/sensors'],
  ])('maps %s on %s to %s', (protocol, host, expectedUrl) => {
    expect(resolveWebSocketUrl({ protocol, host })).toBe(expectedUrl)
  })

  it('uses an explicit override instead of deriving from location', () => {
    expect(
      resolveWebSocketUrl(
        { protocol: 'https:', host: 'example.test' },
        'ws://localhost:8080/ws/sensors',
      ),
    ).toBe('ws://localhost:8080/ws/sensors')
  })

  it('ignores a blank override and falls back to deriving from location', () => {
    expect(resolveWebSocketUrl({ protocol: 'http:', host: 'example.test' }, '')).toBe(
      'ws://example.test/ws/sensors',
    )
  })
})
