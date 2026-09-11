const API_BASE_URL = import.meta.env.VITE_API_URL ?? ''

export interface ApiErrorBody {
  error?: string
  field?: string
  message?: string
  [key: string]: unknown
}

/** Thrown by {@link fetchJson} for any non-ok HTTP response. */
export class ApiError extends Error {
  readonly status: number
  readonly body: ApiErrorBody | null

  constructor(status: number, body: ApiErrorBody | null) {
    super(body?.message ?? `Request failed with status ${status}`)
    this.name = 'ApiError'
    this.status = status
    this.body = body
  }
}

export interface FetchJsonOptions {
  signal?: AbortSignal
}

/**
 * Thin typed wrapper around the browser fetch API for this app's JSON REST
 * endpoints. `path` is appended to `VITE_API_URL` as-is (e.g. `/devices`,
 * matching the backend routes being reachable at `${VITE_API_URL}/devices`).
 */
export async function fetchJson<T>(path: string, options: FetchJsonOptions = {}): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, { signal: options.signal })

  if (!response.ok) {
    let body: ApiErrorBody | null = null
    try {
      body = await response.json()
    } catch {
      body = null
    }
    throw new ApiError(response.status, body)
  }

  return (await response.json()) as T
}
