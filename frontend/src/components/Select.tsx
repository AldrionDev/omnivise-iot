import { useId, type ComponentPropsWithoutRef } from 'react'
import { cn } from '../lib/cn'

export interface SelectOption {
  value: string
  label: string
}

export interface SelectProps extends Omit<ComponentPropsWithoutRef<'select'>, 'onChange'> {
  options: SelectOption[]
  label?: string
  /** Convenience callback receiving the new value directly; native onChange still works via ...rest if omitted. */
  onChange?: (value: string) => void
}

/** Native <select>; a real form control gets listbox semantics for free. */
export function Select({ options, label, id, className, onChange, ...rest }: SelectProps) {
  const generatedId = useId()
  const selectId = id ?? generatedId

  const select = (
    <select
      id={selectId}
      className={cn('rounded-md border border-border bg-surface px-sm py-xs', className)}
      onChange={onChange ? (event) => onChange(event.target.value) : undefined}
      {...rest}
    >
      {options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  )

  if (!label) {
    return select
  }

  return (
    <div className="flex flex-col gap-xs">
      <label htmlFor={selectId} className="text-sm text-muted">
        {label}
      </label>
      {select}
    </div>
  )
}
