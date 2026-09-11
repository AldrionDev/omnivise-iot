/**
 * Shared domain types mirroring the backend's public JSON contracts
 * (issues #70/#73). Kept in one place so the WS/REST wire shape is defined
 * exactly once on the frontend.
 */

export interface Channel {
  channel: string
  unit: string
}

export interface Device {
  deviceId: string
  name: string
  kind: string
  location: string
  channels: Channel[]
}

/**
 * A reading's value is numeric for continuous channels (e.g. intake_temp)
 * and a string for door_contact ("open" | "closed" at runtime -- see
 * SimulatorEngine.doorContact()).
 */
export type SensorValue = number | string

export interface Reading {
  deviceId: string
  channel: string
  value: SensorValue
  unit: string
  timestamp: string
}

export type AlertSeverity = 'warning' | 'critical'
export type AlertState = 'firing' | 'resolved'

/**
 * Every AlertEvent delivered over the public REST/WS contract is already
 * persisted, so `id` is always present on the wire (unlike the backend's
 * internal pre-insert model).
 */
export interface AlertEvent {
  id: string
  ruleId: string
  deviceId: string
  channel: string
  severity: AlertSeverity
  state: AlertState
  triggeredValue: number
  lastValue: number
  startedAt: string
  resolvedAt: string | null
}

export interface ReadingEnvelope {
  kind: 'reading'
  payload: Reading
}

export interface AlertEnvelope {
  kind: 'alert'
  payload: AlertEvent
}

export type LiveEnvelope = ReadingEnvelope | AlertEnvelope

export type ConnectionState = 'connecting' | 'connected' | 'reconnecting' | 'disconnected'
