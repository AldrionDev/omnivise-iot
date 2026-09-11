import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { EmptyState } from './EmptyState'

describe('EmptyState', () => {
  it('renders the title', () => {
    render(<EmptyState title="No devices yet" />)
    expect(screen.getByText('No devices yet')).toBeTruthy()
  })

  it('renders an optional description', () => {
    render(<EmptyState title="No devices yet" description="Check back later." />)
    expect(screen.getByText('Check back later.')).toBeTruthy()
  })

  it('renders an optional action', () => {
    render(<EmptyState title="No devices yet" action={<button>Retry</button>} />)
    expect(screen.getByRole('button', { name: 'Retry' })).toBeTruthy()
  })
})
