import { describe, expect, it } from 'vitest'
import { parseLiveEnvelope } from './parseLiveEnvelope'

const VALID_READING = {
  kind: 'reading',
  payload: {
    deviceId: 'rack-a1',
    channel: 'intake_temp',
    value: 21.4,
    unit: '°C',
    timestamp: '2026-09-11T10:00:00Z',
  },
}

const VALID_DOOR_READING = {
  kind: 'reading',
  payload: {
    deviceId: 'rack-a1',
    channel: 'door_contact',
    value: 'open',
    unit: 'state',
    timestamp: '2026-09-11T10:00:00Z',
  },
}

const VALID_ALERT = {
  kind: 'alert',
  payload: {
    id: '65f0000000000000000000a1',
    ruleId: 'rack-a1-high-temp',
    deviceId: 'rack-a1',
    channel: 'intake_temp',
    severity: 'critical',
    state: 'firing',
    triggeredValue: 32.1,
    lastValue: 32.1,
    startedAt: '2026-09-11T10:00:00Z',
    resolvedAt: null,
  },
}

describe('parseLiveEnvelope', () => {
  it('parses a valid reading envelope', () => {
    expect(parseLiveEnvelope(JSON.stringify(VALID_READING))).toEqual(VALID_READING)
  })

  it('parses a valid reading envelope with a string (door_contact) value', () => {
    expect(parseLiveEnvelope(JSON.stringify(VALID_DOOR_READING))).toEqual(VALID_DOOR_READING)
  })

  it('parses a valid alert envelope', () => {
    expect(parseLiveEnvelope(JSON.stringify(VALID_ALERT))).toEqual(VALID_ALERT)
  })

  it('rejects malformed JSON', () => {
    expect(parseLiveEnvelope('{not json')).toBeNull()
  })

  it('rejects a JSON value that is not an object', () => {
    expect(parseLiveEnvelope('"just a string"')).toBeNull()
    expect(parseLiveEnvelope('42')).toBeNull()
    expect(parseLiveEnvelope('null')).toBeNull()
  })

  it('rejects a missing kind', () => {
    expect(parseLiveEnvelope(JSON.stringify({ payload: VALID_READING.payload }))).toBeNull()
  })

  it('rejects an unknown kind', () => {
    expect(
      parseLiveEnvelope(JSON.stringify({ kind: 'ping', payload: VALID_READING.payload })),
    ).toBeNull()
  })

  it('rejects a reading envelope with a missing payload', () => {
    expect(parseLiveEnvelope(JSON.stringify({ kind: 'reading' }))).toBeNull()
  })

  it('rejects a reading envelope with a missing required field', () => {
    const { unit: _unit, ...rest } = VALID_READING.payload
    expect(
      parseLiveEnvelope(JSON.stringify({ kind: 'reading', payload: rest })),
    ).toBeNull()
  })

  it('rejects a reading envelope with the wrong primitive type', () => {
    expect(
      parseLiveEnvelope(
        JSON.stringify({
          kind: 'reading',
          payload: { ...VALID_READING.payload, deviceId: 123 },
        }),
      ),
    ).toBeNull()
  })

  it('rejects a reading value that is neither number nor string', () => {
    expect(
      parseLiveEnvelope(
        JSON.stringify({
          kind: 'reading',
          payload: { ...VALID_READING.payload, value: true },
        }),
      ),
    ).toBeNull()
  })

  it('rejects an alert envelope with a missing required field', () => {
    const { severity: _severity, ...rest } = VALID_ALERT.payload
    expect(parseLiveEnvelope(JSON.stringify({ kind: 'alert', payload: rest }))).toBeNull()
  })

  it('rejects an alert envelope with an invalid severity', () => {
    expect(
      parseLiveEnvelope(
        JSON.stringify({ kind: 'alert', payload: { ...VALID_ALERT.payload, severity: 'info' } }),
      ),
    ).toBeNull()
  })

  it('rejects an alert envelope with an invalid state', () => {
    expect(
      parseLiveEnvelope(
        JSON.stringify({ kind: 'alert', payload: { ...VALID_ALERT.payload, state: 'unknown' } }),
      ),
    ).toBeNull()
  })

  it('accepts a resolved alert with a string resolvedAt', () => {
    const resolved = { ...VALID_ALERT.payload, state: 'resolved', resolvedAt: '2026-09-11T11:00:00Z' }
    expect(parseLiveEnvelope(JSON.stringify({ kind: 'alert', payload: resolved }))).toEqual({
      kind: 'alert',
      payload: resolved,
    })
  })
})
