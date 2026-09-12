export type ClassValue = string | false | null | undefined

/** Joins truthy class names with a space. No dependency, no merge/dedup semantics. */
export function cn(...values: ClassValue[]): string {
  return values.filter(Boolean).join(' ')
}
