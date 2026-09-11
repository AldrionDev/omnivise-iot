import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError, fetchAlertsSnapshot, fetchJson } from './api'

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

describe('fetchAlertsSnapshot', () => {
  const alert = {
    sequence: 7,
    id: 'a1',
    ruleId: 'r1',
    deviceId: 'rack-a1',
    channel: 'intake_temp',
    severity: 'warning',
    state: 'firing',
    triggeredValue: 31,
    lastValue: 31,
    startedAt: '2026-09-11T08:00:00Z',
    resolvedAt: null,
  }

  it('returns the validated array and atomic watermark', async () => {
    vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify([alert]), {
      status: 200,
      headers: { 'X-Alert-Watermark': '7' },
    }))

    await expect(fetchAlertsSnapshot('/alerts', new AbortController().signal)).resolves.toEqual({
      items: [alert],
      watermark: 7,
    })
  })

  it.each([
    { header: null, body: [alert] },
    { header: '', body: [] },
    { header: '1.0', body: [] },
    { header: '-1', body: [alert] },
    { header: '6', body: [alert] },
    { header: '7', body: [{ ...alert, sequence: 1.5 }] },
  ])('fails closed for an invalid alert snapshot contract', async ({ header, body }) => {
    vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify(body), {
      status: 200,
      headers: header === null ? undefined : { 'X-Alert-Watermark': header },
    }))

    await expect(fetchAlertsSnapshot('/alerts', new AbortController().signal)).rejects.toThrow(
      'Invalid alert snapshot response',
    )
  })
})
