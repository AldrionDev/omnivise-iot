import type { AlertEvent, LiveEnvelope, Reading } from '../types/domain'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function isString(value: unknown): value is string {
  return typeof value === 'string'
}

function isNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

function isReadingPayload(value: unknown): value is Reading {
  if (!isRecord(value)) {
    return false
  }
  return (
    isString(value.deviceId) &&
    isString(value.channel) &&
    (isNumber(value.value) || isString(value.value)) &&
    isString(value.unit) &&
    isString(value.timestamp)
  )
}

export function isAlertEvent(value: unknown): value is AlertEvent {
  if (!isRecord(value)) {
    return false
  }
  return (
    typeof value.sequence === 'number' &&
    Number.isSafeInteger(value.sequence) &&
    value.sequence >= 0 &&
    isString(value.id) &&
    isString(value.ruleId) &&
    isString(value.deviceId) &&
    isString(value.channel) &&
    (value.severity === 'warning' || value.severity === 'critical') &&
    (value.state === 'firing' || value.state === 'resolved') &&
    isNumber(value.triggeredValue) &&
    isNumber(value.lastValue) &&
    isString(value.startedAt) &&
    (value.resolvedAt === null || isString(value.resolvedAt))
  )
}

/**
 * Parses one WebSocket text frame into a typed LiveEnvelope, or null when
 * the frame is not valid JSON, not an object, has an unrecognised `kind`, or
 * has a payload missing/mistyped required fields. Never throws -- callers
 * can ignore a null result safely without touching application state.
 */
export function parseLiveEnvelope(raw: string): LiveEnvelope | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }

  if (!isRecord(parsed)) {
    return null
  }

  if (parsed.kind === 'reading' && isReadingPayload(parsed.payload)) {
    return { kind: 'reading', payload: parsed.payload }
  }

  if (parsed.kind === 'alert' && isAlertEvent(parsed.payload)) {
    return { kind: 'alert', payload: parsed.payload }
  }

  return null
}
