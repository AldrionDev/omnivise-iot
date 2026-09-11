import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { StatDelta } from './StatDelta'

describe('StatDelta', () => {
  it('shows a positive value with a leading +', () => {
    render(<StatDelta value={2.5} />)
    expect(screen.getByText('+2.5')).toBeTruthy()
  })

  it('shows a negative value with its native -', () => {
    render(<StatDelta value={-1.2} />)
    expect(screen.getByText('-1.2')).toBeTruthy()
  })

  it('shows zero without a sign', () => {
    render(<StatDelta value={0} />)
    expect(screen.getByText('0')).toBeTruthy()
  })

  it('exposes the direction to screen readers, not just visually', () => {
    render(<StatDelta value={2.5} />)
    expect(screen.getByText('increased by')).toBeTruthy()
  })

  it('exposes "decreased by" for a negative value', () => {
    render(<StatDelta value={-1.2} />)
    expect(screen.getByText('decreased by')).toBeTruthy()
  })
})
