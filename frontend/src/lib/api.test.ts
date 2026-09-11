import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError, fetchJson } from './api'

beforeEach(() => {
  vi.stubGlobal('fetch', vi.fn())
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('fetchJson', () => {
  it('resolves with the parsed JSON body on a successful response', async () => {
    vi.mocked(fetch).mockResolvedValue(
      new Response(JSON.stringify({ hello: 'world' }), { status: 200 }),
    )

    const result = await fetchJson<{ hello: string }>('/api/devices')

    expect(result).toEqual({ hello: 'world' })
  })

  it('calls fetch with the given path appended to the base URL', async () => {
    vi.mocked(fetch).mockResolvedValue(new Response('{}', { status: 200 }))

    await fetchJson('/devices')

    expect(fetch).toHaveBeenCalledWith(expect.stringContaining('/devices'), expect.anything())
  })

  it('throws an ApiError carrying the status and parsed body on a non-ok response', async () => {
    vi.mocked(fetch).mockResolvedValue(
      new Response(
        JSON.stringify({ error: 'invalid_request', field: 'deviceId', message: 'unknown device' }),
        { status: 400 },
      ),
    )

    await expect(fetchJson('/api/alerts/rules?deviceId=nope')).rejects.toMatchObject({
      status: 400,
      body: { error: 'invalid_request', field: 'deviceId', message: 'unknown device' },
    })
  })

  it('throws an ApiError even when the error body is not JSON', async () => {
    vi.mocked(fetch).mockResolvedValue(new Response('not json', { status: 500 }))

    await expect(fetchJson('/api/devices')).rejects.toBeInstanceOf(ApiError)
  })

  it('propagates AbortError when the signal is aborted', async () => {
    const abortError = new DOMException('The operation was aborted', 'AbortError')
    vi.mocked(fetch).mockRejectedValue(abortError)

    await expect(fetchJson('/api/devices', { signal: new AbortController().signal })).rejects.toBe(
      abortError,
    )
  })
})
