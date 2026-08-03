// Port of the initials logic in esc-chatmail/Views/Components/InitialsAvatarView.swift.
// Two-word names use first letters of the first two words; single words use a
// prefix whose length depends on avatar size (2 for standard 44px, 1 elsewhere).

export function initials(name: string, singleNamePrefixLength: 1 | 2 = 2): string {
  const components = name.split(' ').filter((c) => c.length > 0)
  const first = components[0]
  if (components.length >= 2) {
    const second = components[1]!
    return (first!.slice(0, 1) + second.slice(0, 1)).toUpperCase()
  }
  if (first !== undefined) {
    return first.slice(0, singleNamePrefixLength).toUpperCase()
  }
  return '?'
}
