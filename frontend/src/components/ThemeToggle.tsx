import { useTheme } from '../theme/ThemeProvider'
import { Button } from './Button'

export function ThemeToggle() {
  const { theme, toggleTheme } = useTheme()
  const nextTheme = theme === 'dark' ? 'light' : 'dark'

  return (
    <Button variant="ghost" size="sm" onClick={toggleTheme} aria-label={`Switch to ${nextTheme} theme`}>
      {theme === 'dark' ? '🌙' : '☀️'}
    </Button>
  )
}
