import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { Button } from './Button'

describe('Button', () => {
  it('renders a native button element', () => {
    render(<Button>Click me</Button>)
    const button = screen.getByRole('button', { name: 'Click me' })
    expect(button.tagName).toBe('BUTTON')
  })

  it('defaults type to "button" so it never submits an enclosing form', () => {
    render(<Button>Click me</Button>)
    expect(screen.getByRole('button')).toHaveProperty('type', 'button')
  })

  it('lets a caller override the native type', () => {
    render(<Button type="submit">Save</Button>)
    expect(screen.getByRole('button')).toHaveProperty('type', 'submit')
  })

  it('forwards native props such as onClick and disabled', () => {
    const onClick = vi.fn()
    render(
      <Button onClick={onClick} disabled>
        Click me
      </Button>,
    )
    const button = screen.getByRole('button')
    fireEvent.click(button)

    expect(onClick).not.toHaveBeenCalled()
    expect(button).toHaveProperty('disabled', true)
  })
})
