import { describe, expect, it } from 'vitest'
import { cn } from './cn'

describe('cn', () => {
  it('drops falsy entries', () => {
    expect(cn('a', undefined, null, '', 'c')).toBe('a c')
  })

  it('lets later tailwind utilities win conflicts', () => {
    expect(cn('p-2', 'p-4')).toBe('p-4')
  })
})
