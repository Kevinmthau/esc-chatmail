# Golden Message Corpus

Fixture file: `golden_message_corpus.json`

Test harness: `GoldenCorpusReplayTests` in `esc-chatmailTests/MessageProcessorTests.swift`

## Purpose

Each fixture is a real regression example. Add a new case whenever message cleaning,
preview routing, or newsletter scoring fails in production.

## Sections

- `plainTextQuoteCleanupCases`: raw plain text -> expected bubble text
- `htmlToBubbleTextCases`: raw HTML -> expected bubble text
- `displayPolicyCases`: preview routing decisions
- `newsletterDetectionCases`: newsletter score/classification expectations

## Run

```bash
bash Scripts/run-tests.sh -only-testing 'esc-chatmailTests/GoldenCorpusReplayTests'
```

## Workflow

1. Add a failing sample to the appropriate section.
2. Run the corpus replay test and confirm it fails.
3. Fix parser/policy logic.
4. Re-run corpus replay test and keep the fixture permanently.
