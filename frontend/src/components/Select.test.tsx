import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { Select } from './Select'

const OPTIONS = [
  { value: 'a', label: 'Option A' },
  { value: 'b', label: 'Option B' },
]

describe('Select', () => {
  it('renders a native select with the given options', () => {
    render(<Select value="a" onChange={() => {}} options={OPTIONS} />)
    const select = screen.getByRole('combobox')
    expect(select.tagName).toBe('SELECT')
    expect(screen.getByRole('option', { name: 'Option A' })).toBeTruthy()
    expect(screen.getByRole('option', { name: 'Option B' })).toBeTruthy()
  })

  it('associates a visible label via htmlFor/id', () => {
    render(<Select label="Channel" value="a" onChange={() => {}} options={OPTIONS} />)
    const select = screen.getByLabelText('Channel')
    expect(select.tagName).toBe('SELECT')
  })

  it('calls onChange with the selected value, without owning the value itself', () => {
    const onChange = vi.fn()
    render(<Select value="a" onChange={onChange} options={OPTIONS} />)

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'b' } })

    expect(onChange).toHaveBeenCalledWith('b')
  })

  it('forwards native select props such as disabled', () => {
    render(<Select value="a" onChange={() => {}} options={OPTIONS} disabled />)
    expect(screen.getByRole('combobox')).toHaveProperty('disabled', true)
  })
})
