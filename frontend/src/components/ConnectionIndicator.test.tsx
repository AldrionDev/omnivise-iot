import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { ConnectionIndicator } from './ConnectionIndicator'

describe('ConnectionIndicator', () => {
  it.each([
    ['connecting', 'Connecting'],
    ['connected', 'Connected'],
    ['reconnecting', 'Reconnecting'],
    ['disconnected', 'Disconnected'],
  ] as const)('shows a visible label for %s', (state, expectedLabel) => {
    render(<ConnectionIndicator state={state} />)
    expect(screen.getByText(expectedLabel)).toBeTruthy()
  })
})
