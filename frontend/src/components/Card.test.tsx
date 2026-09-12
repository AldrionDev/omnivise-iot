import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Card } from './Card'

describe('Card', () => {
  it('renders children inside a div', () => {
    render(<Card>hello</Card>)
    const card = screen.getByText('hello')
    expect(card.tagName).toBe('DIV')
  })

  it('merges an extra className with its own defaults', () => {
    render(<Card className="extra-class">content</Card>)
    expect(screen.getByText('content').className).toContain('extra-class')
  })
})
