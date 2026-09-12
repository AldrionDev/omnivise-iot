export type HistoryRange = '15m' | '1h' | '24h'
export type HistoryBucket = '1m' | '5m' | '1h'

export interface HistoryWindow {
  bucket: HistoryBucket
  from: string
  to: string
}

const RANGE_MS: Record<HistoryRange, number> = {
  '15m': 15 * 60_000,
  '1h': 60 * 60_000,
  '24h': 24 * 60 * 60_000,
}

/**
 * Approved range -> bucket mapping (issue #75): each stays well under the
 * backend's MAX_BUCKET_COUNT=1000 while keeping charts readable.
 */
const RANGE_BUCKET: Record<HistoryRange, HistoryBucket> = {
  '15m': '1m',
  '1h': '5m',
  '24h': '1h',
}

export const HISTORY_RANGES: HistoryRange[] = ['15m', '1h', '24h']

/**
 * Derives the {bucket, from, to} for one channel's history request. `to`
 * should be captured once per refresh and passed to every channel so all
 * requests in the same refresh share an identical from/to pair.
 */
export function resolveHistoryWindow(range: HistoryRange, to: Date): HistoryWindow {
  const from = new Date(to.getTime() - RANGE_MS[range])
  return {
    bucket: RANGE_BUCKET[range],
    from: from.toISOString(),
    to: to.toISOString(),
  }
}
