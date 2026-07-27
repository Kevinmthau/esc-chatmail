// Sender-run grouping for chat bubbles (port of the grouping behavior in
// esc-chatmail/Views/Chat/ChatMessagesView.swift): consecutive messages from
// the same sender form a run; only the last message of a run shows the avatar
// (the rest render a same-width spacer), and in group conversations incoming
// messages show the sender name on the first message of each run.

export interface RunInput {
  id: string
  senderEmail: string
  isFromMe: boolean
}

export interface RunDecoration {
  /** True on the last message of a consecutive same-sender run. */
  isLastOfRun: boolean
  /** True on the first message of a consecutive same-sender run. */
  isFirstOfRun: boolean
  /** Show the avatar slot filled (incoming only, last of run). */
  showAvatar: boolean
  /** Show the sender name above the bubble (groups, incoming, first of run). */
  showSenderName: boolean
}

export function computeRuns(
  messages: readonly RunInput[],
  opts: { isGroup: boolean },
): Map<string, RunDecoration> {
  const out = new Map<string, RunDecoration>()
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i]!
    const prev = messages[i - 1]
    const next = messages[i + 1]
    const sameAsPrev = prev !== undefined && prev.senderEmail === m.senderEmail
    const sameAsNext = next !== undefined && next.senderEmail === m.senderEmail
    const isFirstOfRun = !sameAsPrev
    const isLastOfRun = !sameAsNext
    out.set(m.id, {
      isFirstOfRun,
      isLastOfRun,
      showAvatar: !m.isFromMe && isLastOfRun,
      showSenderName: opts.isGroup && !m.isFromMe && isFirstOfRun,
    })
  }
  return out
}
