const WEB_SOCKET_PATH = '/ws/sensors'

export function getWebSocketUrl({ protocol, host }) {
  const webSocketProtocol = protocol === 'https:' ? 'wss:' : 'ws:'

  return `${webSocketProtocol}//${host}${WEB_SOCKET_PATH}`
}
