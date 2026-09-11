import type { AlertEvent } from '../types/domain'

export interface AlertStore {
  readonly byId: Readonly<Record<string, AlertEvent>>
  /** New live IDs by sequence, followed by IDs in authoritative snapshot order. */
  readonly order: readonly string[]
  readonly liveSequence: Readonly<Record<string, number>>
}

/**
 * Alert sequence is the only lifecycle ordering authority. Keeping resolved
 * events in this store provides tombstones for active-alert views.
 */
export function mergeAlert(store: AlertStore, incoming: AlertEvent): AlertStore {
  const existing = store.byId[incoming.id]
  if (existing && existing.sequence >= incoming.sequence) {
    return store
  }
  if (existing) {
    return { ...store, byId: { ...store.byId, [incoming.id]: incoming } }
  }

  let insertionIndex = 0
  while (insertionIndex < store.order.length) {
    const precedingSequence = store.liveSequence[store.order[insertionIndex]]
    if (precedingSequence === undefined || precedingSequence < incoming.sequence) break
    insertionIndex++
  }
  const order = store.order.slice()
  order.splice(insertionIndex, 0, incoming.id)
  return {
    byId: { ...store.byId, [incoming.id]: incoming },
    order,
    liveSequence: { ...store.liveSequence, [incoming.id]: incoming.sequence },
  }
}

export function createAlertStore(events: AlertEvent[]): AlertStore {
  const byId: Record<string, AlertEvent> = {}
  const order: string[] = []
  for (const event of events) {
    const existing = byId[event.id]
    if (!existing) order.push(event.id)
    if (!existing || event.sequence > existing.sequence) byId[event.id] = event
  }
  return { byId, order, liveSequence: {} }
}

export function replayAlerts(
  snapshot: AlertEvent[],
  journal: AlertEvent[],
  watermark: number,
): AlertStore {
  return journal
    .filter((event) => event.sequence > watermark)
    .sort((a, b) => a.sequence - b.sequence)
    .reduce<AlertStore>((store, event) => mergeAlert(store, event), createAlertStore(snapshot))
}

export function selectActiveAlerts(store: AlertStore): AlertEvent[] {
  return store.order
    .map((id) => store.byId[id])
    .filter((alert) => alert.state === 'firing')
}

export function selectRecentAlerts(
  store: AlertStore,
  limit: number,
  matches: (alert: AlertEvent) => boolean = () => true,
): AlertEvent[] {
  return store.order
    .map((id) => store.byId[id])
    .filter(matches)
    .slice(0, limit)
}
