import type { ComponentPropsWithoutRef } from 'react'
import { cn } from '../lib/cn'

export type ButtonVariant = 'primary' | 'secondary' | 'ghost'
export type ButtonSize = 'sm' | 'md'

export interface ButtonProps extends ComponentPropsWithoutRef<'button'> {
  variant?: ButtonVariant
  size?: ButtonSize
}

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: 'bg-accent text-background hover:opacity-90',
  secondary: 'bg-surface-raised text-foreground hover:opacity-90',
  ghost: 'bg-transparent text-foreground hover:bg-surface-raised',
}

const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: 'text-sm px-sm py-xs',
  md: 'text-base px-md py-sm',
}

/** Native <button>; all accessibility semantics come from the real element. */
export function Button({
  variant = 'primary',
  size = 'md',
  type = 'button',
  className,
  ...rest
}: ButtonProps) {
  return (
    <button
      type={type}
      className={cn(
        'rounded-md font-sans disabled:opacity-50 disabled:cursor-not-allowed',
        VARIANT_CLASSES[variant],
        SIZE_CLASSES[size],
        className,
      )}
      {...rest}
    />
  )
}
