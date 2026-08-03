import { describe, expect, it } from 'vitest'
import { computeRuns } from './bubbleRuns'

const msg = (id: string, senderEmail: string, isFromMe = false) => ({ id, senderEmail, isFromMe })

describe('computeRuns', () => {
  it('shows avatar only on the last message of a run', () => {
    const runs = computeRuns([msg('1', 'a@x.com'), msg('2', 'a@x.com'), msg('3', 'b@x.com')], {
      isGroup: false,
    })
    expect(runs.get('1')!.showAvatar).toBe(false)
    expect(runs.get('2')!.showAvatar).toBe(true)
    expect(runs.get('3')!.showAvatar).toBe(true)
  })

  it('never shows avatar for own messages', () => {
    const runs = computeRuns([msg('1', 'me@x.com', true)], { isGroup: false })
    expect(runs.get('1')!.showAvatar).toBe(false)
  })

  it('shows sender name on first of run, incoming, groups only', () => {
    const group = computeRuns(
      [msg('1', 'a@x.com'), msg('2', 'a@x.com'), msg('3', 'me@x.com', true)],
      { isGroup: true },
    )
    expect(group.get('1')!.showSenderName).toBe(true)
    expect(group.get('2')!.showSenderName).toBe(false)
    expect(group.get('3')!.showSenderName).toBe(false)

    const oneToOne = computeRuns([msg('1', 'a@x.com')], { isGroup: false })
    expect(oneToOne.get('1')!.showSenderName).toBe(false)
  })

  it('breaks runs on sender change even when alternating', () => {
    const runs = computeRuns([msg('1', 'a@x.com'), msg('2', 'b@x.com'), msg('3', 'a@x.com')], {
      isGroup: false,
    })
    expect(runs.get('1')!.isLastOfRun).toBe(true)
    expect(runs.get('2')!.isLastOfRun).toBe(true)
    expect(runs.get('3')!.isLastOfRun).toBe(true)
  })
})
