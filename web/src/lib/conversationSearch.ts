// Port of ConversationFilterService.matchesSearch
// (esc-chatmail/Services/ConversationList/ConversationFilterService.swift).
//
// Local search only: iOS matches the query against the conversation's rolled-up
// displayName and snippet — never message bodies — so a chat surfaces by who it
// is with or by what its latest preview says. Keeping that scope is what makes
// the web list agree with the phone for the same mailbox.

/** The rolled-up conversation fields iOS searches over. */
export interface ConversationSearchable {
  displayName: string
  snippet: string
}

/**
 * True when `conversation` should stay visible for `query`.
 *
 * An empty query matches everything (search is off). Otherwise the match is a
 * case-insensitive substring test, exactly as iOS does it: `.lowercased()` on
 * both sides then `contains`. The query is deliberately NOT trimmed — iOS's
 * final visibility gate passes the raw debounced text to `matchesSearch`, so a
 * trailing space narrows results there too, and diverging here would make the
 * two clients disagree on the same keystrokes.
 */
export function matchesConversationSearch(
  conversation: ConversationSearchable,
  query: string,
): boolean {
  if (query === '') return true
  const needle = query.toLowerCase()
  return (
    conversation.displayName.toLowerCase().includes(needle) ||
    conversation.snippet.toLowerCase().includes(needle)
  )
}
