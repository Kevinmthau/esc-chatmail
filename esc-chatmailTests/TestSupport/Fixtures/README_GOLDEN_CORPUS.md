# Golden Message Corpus

Fixture file: `golden_message_corpus.json`

Test harness: `GoldenCorpusReplayTests` in `esc-chatmailTests/Sync/MessageProcessorTests.swift`

## Purpose

Each fixture is a real regression example. Add a new case whenever message cleaning,
preview routing, or newsletter scoring fails in production.

The web tests import this same JSON through the `@fixtures` alias. MIME replay
lives in `web/src/mime/corpus.golden.test.ts`, display-policy and rich-HTML replay
in `web/src/lib/displayPolicy.test.ts`, and list-snippet replay in
`web/src/rollup/rollup.test.ts`. Keep expected results shared across platforms;
changes under `Fixtures/` also trigger web CI.

## Sections

- `plainTextQuoteCleanupCases`: raw plain text -> expected bubble text
- `htmlToBubbleTextCases`: raw HTML -> expected bubble text
- `rawSourceHTMLRecoveryCases`: raw RFC822 source -> expected extracted HTML/rich-preview behavior
- `richHTMLDetectionCases`: raw HTML -> expected hasRichHTMLContent (used for preview routing)
- `displayPolicyCases`: all nine preview-routing inputs, including `isLikelyCalendarInvite`
- `conversationListSnippetCases`: conversation rollup snippet -> expected list-row snippet
- `cleanedSnippetCases`: HTML/plain/raw inputs -> ingest-owned cleaned snippet
- `conversationIdentityCases`: headers + aliases -> participants, fixed SHA-256 hash, type, and List-Id
- `newsletterDetectionCases`: newsletter score/classification expectations

## Run

```bash
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/GoldenCorpusReplayTests'
```

From `web/`:

```bash
corepack pnpm test src/mime/corpus.golden.test.ts src/lib/displayPolicy.test.ts src/rollup/rollup.test.ts
```

## Workflow

1. Add a failing sample to the appropriate section.
2. Run the corpus replay test and confirm it fails.
3. Fix parser/policy logic.
4. Re-run corpus replay test and keep the fixture permanently.

## Shared identity and display contracts

`ConversationIdentityTests` and `web/src/identity/participantSet.test.ts` replay
`conversationIdentityCases` through each platform's production header path.
The fixed hashes include Gmail normalization, self/BCC/Hide My Email exclusion,
malformed display-name brackets, and Swift Unicode ordering. These cases cover
participant identities (`listId: null`); the web app does not yet implement the
iOS List-Id identity model, so list grouping is not claimed as a shared contract.

`GoldenCorpusReplayTests` replays `cleanedSnippetCases` through MIME ingest;
`web/src/mime/corpus.golden.test.ts` replays the existing cleaned-snippet function.
The snippet and chat-preview pipelines remain separate. Calendar cases include
source, reply, and outgoing precedence so the ninth display-policy input cannot
be silently dropped. Swift takes those inputs in `MessageDisplayInput`, matching
the web value type.

Run all shared contracts, including identity:

```bash
./Scripts/codex-test.sh -only-testing 'esc-chatmailTests/GoldenCorpusReplayTests' -only-testing 'esc-chatmailTests/ConversationIdentityTests'
```

From `web/`:

```bash
corepack pnpm test src/identity/participantSet.test.ts src/mime/corpus.golden.test.ts src/lib/displayPolicy.test.ts src/rollup/rollup.test.ts
```
