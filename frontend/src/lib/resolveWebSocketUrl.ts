const WEB_SOCKET_PATH = '/ws/sensors'

export interface LocationLike {
  protocol: string
  host: string
}

/**
 * Resolves the backend WebSocket URL.
 *
 * An explicit, non-empty `override` (`VITE_WS_URL`) is authoritative --
 * matches the existing dev-vs-prod runtime wiring where the dev server talks
 * directly to the backend and production goes through the Nginx reverse
 * proxy on the current origin. Otherwise the URL is derived from the
 * browser's own location, mapping http/https to ws/wss.
 */
export function resolveWebSocketUrl(location: LocationLike, override?: string): string {
  if (override) {
    return override
  }

  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${protocol}//${location.host}${WEB_SOCKET_PATH}`
}
