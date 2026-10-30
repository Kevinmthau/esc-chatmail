// Port of the initials logic in esc-chatmail/Views/Components/InitialsAvatarView.swift.
// Two-word names use first letters of the first two words; single words use a
// prefix whose length depends on avatar size (2 for standard 44px, 1 elsewhere).

// Swift's `prefix(n)` counts Characters (grapheme clusters). `String.slice`
// counts UTF-16 code units, which cuts an astral first character — an emoji,
// a flag, CJK Extension B — in half and renders the lone surrogate as U+FFFD.
const graphemeSegmenter: Intl.Segmenter | null =
  typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
    ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
    : null

/** The first `count` grapheme clusters (code points without Intl.Segmenter). */
function graphemePrefix(word: string, count: number): string {
  if (graphemeSegmenter === null) return [...word].slice(0, count).join('')
  let prefix = ''
  let taken = 0
  for (const { segment } of graphemeSegmenter.segment(word)) {
    if (taken >= count) break
    prefix += segment
    taken += 1
  }
  return prefix
}

export function initials(name: string, singleNamePrefixLength: 1 | 2 = 2): string {
  const components = name.split(' ').filter((c) => c.length > 0)
  const first = components[0]
  if (components.length >= 2) {
    const second = components[1]!
    return (graphemePrefix(first!, 1) + graphemePrefix(second, 1)).toUpperCase()
  }
  if (first !== undefined) {
    return graphemePrefix(first, singleNamePrefixLength).toUpperCase()
  }
  return '?'
}
