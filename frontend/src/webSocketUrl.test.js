import { describe, expect, it } from 'vitest'
import { getWebSocketUrl } from './webSocketUrl'

describe('getWebSocketUrl', () => {
  it.each([
    ['http:', 'example.test', 'ws://example.test/ws/sensors'],
    ['https:', 'example.test', 'wss://example.test/ws/sensors'],
    ['http:', 'example.test:3000', 'ws://example.test:3000/ws/sensors'],
    ['https:', 'example.test:8443', 'wss://example.test:8443/ws/sensors'],
  ])('maps %s on %s to %s', (protocol, host, expectedUrl) => {
    expect(getWebSocketUrl({ protocol, host })).toBe(expectedUrl)
  })
})
