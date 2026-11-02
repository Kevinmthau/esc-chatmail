// One-shot repair for subjects stored before `extractHeaders` (mime/parse)
// decoded RFC 2047 encoded words: the Message.subject half of iOS's
// DataCleanupService.decodeRFC2047HeaderTextIfNeeded. Ingestion now stores
// the decoded subject, but Gmail never re-sends a message it already
// delivered, so a row synced earlier keeps "=?utf-8?B?…?=" until this pass
// runs. Its conversation's stored snippet can spell it too (`Fwd: "=?…?="`),
// and a fully encoded "Fwd:" subject hid the forward from the preview.
//
// This is a sync-time pass, not a Dexie `.upgrade()` like db/schema's v2.
// An upgrade runs inside the database open, so one that throws fails the
// open and locks the user out of the account store until a fix ships. The v2
// upgrade only writes a constant; this pass runs the decoder and the rollup
// over arbitrary stored text. Here a failure is logged and the next sync
// retries. Like the iOS migration keys, the flag is versioned: bump it when
// the decoder learns a new shape, such as a charset, so stores that latched
// it rescan the subjects it left encoded.
//
// iOS decodes Conversation.snippet in place. Here the snippet comes from the
// rollup instead, which is the only way a decoded "Fwd:" prefix turns the
// preview into `Fwd: "…"`, as a fresh sync of the same message would.
//
// Not repaired: the newsletter and calendar-invite verdicts, and an outgoing
// forward's chatPreviewText. All three read the subject at parse time, but
// they also need headers or MIME parts that are not stored.

import type { ChatmailDB } from '@/db/schema'
import type { MessageRow } from '@/db/types'
import { invitedSubjectTitle } from '@/mime/calendarInvite'
import { containsEncodedWord, decodeRfc2047 } from '@/mime/rfc2047Decoder'
import { rollupConversation } from '@/rollup/rollup'

export const ENCODED_SUBJECT_REPAIR_KEY = 'decodedRfc2047SubjectsV1'

export interface EncodedSubjectRepairResult {
  /** False means the flag was already set. */
  performed: boolean
  decodedSubjectCount: number
  /** Calendar events whose title fell back to the encoded subject. */
  retitledCalendarEventCount: number
  recomputedConversationCount: number
}

/**
 * Runs the repair. A failure is logged and retried at the next sync, and the
 * sync that ran it carries on with the subjects it stored before the repair.
 */
export async function repairStoredSubjectsIfNeeded(db: ChatmailDB, now: number): Promise<void> {
  try {
    await decodeEncodedSubjectsIfNeeded(db, now)
  } catch (error) {
    console.warn('[subjects] RFC 2047 subject repair failed; will retry', error)
  }
}

/**
 * Decodes the stored subjects that hold an RFC 2047 encoded word and
 * recomputes their conversations' rollups. One Dexie transaction reads the
 * flag first and writes it last, so the flag commits together with the
 * decoded rows and the recomputed rollups, or not at all.
 *
 * A subject the decoder leaves unchanged (a charset it cannot decode, "=?"
 * that is not an encoded word) is not rewritten, and its conversation is not
 * recomputed.
 */
export async function decodeEncodedSubjectsIfNeeded(
  db: ChatmailDB,
  now: number,
): Promise<EncodedSubjectRepairResult> {
  return db.transaction(
    'rw',
    [db.syncState, db.messages, db.conversations, db.convoParticipants, db.people],
    async () => {
      const flag = await db.syncState.get(ENCODED_SUBJECT_REPAIR_KEY)
      if (flag?.value === true) {
        return {
          performed: false,
          decodedSubjectCount: 0,
          retitledCalendarEventCount: 0,
          recomputedConversationCount: 0,
        }
      }

      const candidates = await db.messages
        .filter((message) => containsEncodedWord(message.subject))
        .toArray()

      const repaired: MessageRow[] = []
      const conversationIds = new Set<string>()
      let retitledCalendarEventCount = 0
      for (const message of candidates) {
        const decoded = decodeRfc2047(message.subject)
        if (decoded === message.subject) continue

        // analyzeCalendarInvite titles an event with no SUMMARY from the same
        // subject this row stored, so a title equal to that fallback came from
        // the encoded subject. A SUMMARY title stays as the invite spelled it.
        const event = message.calendarEvent
        if (event !== undefined && event.title === invitedSubjectTitle(message.subject)) {
          message.calendarEvent = { ...event, title: invitedSubjectTitle(decoded) }
          retitledCalendarEventCount += 1
        }
        message.subject = decoded
        repaired.push(message)
        conversationIds.add(message.conversationId)
      }

      if (repaired.length > 0) {
        await db.messages.bulkPut(repaired)
        // Nested into this transaction, so each rollup reads the decoded rows.
        for (const conversationId of conversationIds) {
          await rollupConversation(db, conversationId, now)
        }
      }

      // Last write by design: it commits with the repaired rows or not at all.
      await db.syncState.put({ key: ENCODED_SUBJECT_REPAIR_KEY, value: true })

      return {
        performed: true,
        decodedSubjectCount: repaired.length,
        retitledCalendarEventCount,
        recomputedConversationCount: conversationIds.size,
      }
    },
  )
}
