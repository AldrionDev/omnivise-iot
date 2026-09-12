import type { Device, HistoryPoint, Reading } from '../types/domain'

/** A single point in an aggregated, unit-less headline-metric sparkline. */
export interface SparklinePoint {
  t: string
  value: number | null
}

/** Devices whose channel list includes the given channel name. */
export function devicesWithChannel(devices: Device[], channel: string): Device[] {
  return devices.filter((device) => device.channels.some((c) => c.channel === channel))
}

export function maxOf(values: number[]): number {
  return Math.max(...values)
}

export function sumOf(values: number[]): number {
  return values.reduce((total, value) => total + value, 0)
}

function numericReadingValue(reading: Reading | undefined): number | null {
  return reading && typeof reading.value === 'number' ? reading.value : null
}

/**
 * Combines the live reading at `${deviceId}::${channel}` across a set of
 * contributing devices (from {@link LiveStreamContext.latestReadings}), e.g.
 * max rack exhaust temperature across every rack, or a room-level power draw
 * from one aggregate PDU. A door_contact-style string reading is not numeric
 * and is ignored. `null` when none of the contributing keys have a live
 * reading yet -- callers render this as an explicit loading/empty state rather
 * than a misleading zero.
 */
export function aggregateLatestValue(
  deviceIds: string[],
  channel: string,
  latestReadings: Record<string, Reading>,
  combine: (values: number[]) => number,
): number | null {
  const values = deviceIds
    .map((deviceId) => numericReadingValue(latestReadings[`${deviceId}::${channel}`]))
    .filter((value): value is number => value !== null)
  return values.length === 0 ? null : combine(values)
}

/** Maps one channel's history points to sparkline points via `avg`. */
export function toSparklinePoints(points: HistoryPoint[]): SparklinePoint[] {
  return points.map((point) => ({ t: point.t, value: point.avg }))
}

/**
 * Merges multiple devices' history series (fetched with the same shared
 * `from`/`to`/`bucket` window, see {@link resolveHistoryWindow}) into one
 * aggregated sparkline series, aligned by bucket timestamp. A bucket a
 * sparser series has no data for simply combines over whichever series do; a
 * null `avg` point is skipped rather than treated as zero.
 */
export function mergeHistorySeries(
  seriesList: HistoryPoint[][],
  combine: (values: number[]) => number,
): SparklinePoint[] {
  const byTimestamp = new Map<string, number[]>()
  for (const series of seriesList) {
    for (const point of series) {
      if (point.avg === null) {
        continue
      }
      const values = byTimestamp.get(point.t) ?? []
      values.push(point.avg)
      byTimestamp.set(point.t, values)
    }
  }
  return [...byTimestamp.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([t, values]) => ({ t, value: combine(values) }))
}
