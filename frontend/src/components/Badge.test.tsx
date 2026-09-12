import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Badge } from './Badge'

describe('Badge', () => {
  it('renders its text content in a span', () => {
    render(<Badge variant="ok">Healthy</Badge>)
    const badge = screen.getByText('Healthy')
    expect(badge.tagName).toBe('SPAN')
  })

  it.each([
    ['ok', 'status-ok'],
    ['warning', 'status-warning'],
    ['critical', 'status-critical'],
    ['neutral', 'muted'],
  ] as const)('variant %s uses a token-backed class, not an arbitrary color', (variant, expectedFragment) => {
    render(<Badge variant={variant}>label</Badge>)
    expect(screen.getByText('label').className).toContain(expectedFragment)
  })
})
