import { fireEvent, render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it } from 'vitest'
import { ThemeProvider, THEME_STORAGE_KEY, useTheme } from './ThemeProvider'

function ThemeProbe() {
  const { theme, toggleTheme } = useTheme()
  return (
    <div>
      <span data-testid="theme-value">{theme}</span>
      <button onClick={toggleTheme}>toggle</button>
    </div>
  )
}

function renderProbe() {
  return render(
    <ThemeProvider>
      <ThemeProbe />
    </ThemeProvider>,
  )
}

describe('ThemeProvider', () => {
  beforeEach(() => {
    localStorage.clear()
    document.documentElement.removeAttribute('data-theme')
  })

  it('defaults to dark when nothing is stored', () => {
    renderProbe()
    expect(screen.getByTestId('theme-value').textContent).toBe('dark')
    expect(document.documentElement.dataset.theme).toBe('dark')
  })

  it('honours a stored "dark" value', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'dark')
    renderProbe()
    expect(screen.getByTestId('theme-value').textContent).toBe('dark')
  })

  it('honours a stored "light" value', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'light')
    renderProbe()
    expect(screen.getByTestId('theme-value').textContent).toBe('light')
    expect(document.documentElement.dataset.theme).toBe('light')
  })

  it('falls back to dark for an invalid stored value', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'system')
    renderProbe()
    expect(screen.getByTestId('theme-value').textContent).toBe('dark')
  })

  it('toggles dark to light and persists it', () => {
    renderProbe()

    fireEvent.click(screen.getByRole('button', { name: 'toggle' }))

    expect(screen.getByTestId('theme-value').textContent).toBe('light')
    expect(document.documentElement.dataset.theme).toBe('light')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('light')
  })

  it('toggles light back to dark and persists it', () => {
    localStorage.setItem(THEME_STORAGE_KEY, 'light')
    renderProbe()

    fireEvent.click(screen.getByRole('button', { name: 'toggle' }))

    expect(screen.getByTestId('theme-value').textContent).toBe('dark')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark')
  })

  it('survives a provider remount', () => {
    const { unmount } = renderProbe()

    fireEvent.click(screen.getByRole('button', { name: 'toggle' }))
    expect(screen.getByTestId('theme-value').textContent).toBe('light')

    unmount()
    renderProbe()

    expect(screen.getByTestId('theme-value').textContent).toBe('light')
  })
})
