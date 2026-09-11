/**
 * A minimal, test-controlled stand-in for the browser WebSocket, using the
 * onX property style (matching how useLiveStream wires up handlers). Install
 * with `vi.stubGlobal('WebSocket', MockWebSocket)`.
 */
export class MockWebSocket {
  static instances: MockWebSocket[] = []

  static reset() {
    MockWebSocket.instances = []
  }

  url: string
  /** True once close() has been called on this socket. */
  closeRequested = false
  /** True once the close event has actually been delivered (via triggerClose()). */
  closed = false
  onopen: (() => void) | null = null
  onmessage: ((event: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null

  constructor(url: string) {
    this.url = url
    MockWebSocket.instances.push(this)
  }

  /**
   * Mirrors the real WebSocket#close() contract: synchronously marks the
   * socket as closing, but does NOT deliver the close event synchronously.
   * A real close event arrives asynchronously (often after other code --
   * including a later React effect instance -- has already run); tests use
   * triggerClose() to deliver it whenever they want to reproduce that
   * ordering, including "after a replacement socket already exists".
   */
  close() {
    this.closeRequested = true
  }

  triggerOpen() {
    this.onopen?.()
  }

  triggerMessage(data: string) {
    this.onmessage?.({ data })
  }

  triggerClose() {
    if (this.closed) {
      return
    }
    this.closed = true
    this.onclose?.()
  }

  triggerError() {
    this.onerror?.()
  }
}
