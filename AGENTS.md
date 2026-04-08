# AGENTS.md

## Purpose
This repository is an iOS app focused on making email feel like chat while preserving message fidelity where it matters.
When making changes, optimize for:
1. correctness
2. readability
3. minimal diffs
4. preserving existing architecture unless there is a clear improvement

## Repo-specific priorities
Important areas include:
- HTMLContentLoader
- HTMLSanitizerService
- HTMLDisplayWrapper
- BaseEmailWebView
- preview rendering in chat/thread UI

Be especially careful when changing code that affects both preview rendering and full-message rendering.
Default to separating those paths rather than sharing a single transformed HTML pipeline.

## Product principles
- Full message view should prioritize fidelity to the original email.
- Chat previews are allowed to be derived representations optimized for speed, clarity, and stable layout.
- Do not use preview-specific transformations to degrade the full message rendering path.
- Prefer predictable UI over clever rendering tricks.
- Avoid fragile solutions that depend on scaling full email HTML documents.

## How to work
- Start by reading the relevant code paths before editing.
- Prefer small, reviewable commits.
- Reuse existing patterns and naming conventions in the repo.
- Do not introduce broad rewrites unless they are necessary to complete the task.
- Do not add dependencies unless absolutely necessary.
- Prefer native SwiftUI/UIKit solutions over adding complex parsing frameworks.
- Prefer simple heuristics and maintainable code over overfitting edge cases.

## Architecture guidance
When working on email rendering or previews, keep these concerns separated:
1. source selection
2. canonical normalization
3. safety sanitization
4. presentation

Do not mix preview logic into the full-message rendering path unless required.

## Rendering guidance
### Full message rendering
- Preserve original HTML as much as possible.
- Keep sanitization and security protections intact.
- Minimize layout-altering wrapper CSS.
- Avoid destructive transformations unless clearly required for safety or rendering.

### Chat previews
- For newsletter-like messages, prefer a derived preview model or preview-specific fragment.
- Do not render the full original email HTML at a reduced scale for chat previews unless explicitly requested.
- Favor stable card-like previews with predictable height and fast scrolling.
- Regular conversational email should keep lightweight text-style previews.

## Code style
- Keep code straightforward and readable.
- Prefer explicit names over clever abstractions.
- Avoid unnecessary indirection.
- Keep functions focused and single-purpose.
- Add comments only where they clarify intent or non-obvious tradeoffs.
- Avoid “AI-sounding” abstractions and boilerplate-heavy code.

## Testing
Before finishing:
- Run the narrowest relevant tests first.
- Then run broader tests if the change touches shared infrastructure.
- Do not claim something works unless you ran the relevant checks or clearly state what was not run.
- If tests fail, diagnose whether the failure is caused by your change or is pre-existing.

## Expected workflow for tasks
1. Inspect the current implementation.
2. Identify the minimum set of files to change.
3. Make the smallest clean change that satisfies the task.
4. Run relevant tests or build checks.
5. Summarize:
   - what changed
   - why it changed
   - what was validated
   - any follow-up opportunities

## For UI changes
- Keep visual output intentional and polished.
- Prefer consistency with iOS conventions.
- Avoid unstable WebView hacks when a simpler native UI would work.
- Preserve scrolling performance.

## For email HTML changes
- Be conservative.
- Assume email HTML is fragile.
- Avoid repeated sanitization or repeated transformation passes.
- Avoid mutating canonical content just to improve a preview.
- If preview behavior and fidelity conflict, separate the paths.

## For refactors
- Do not refactor unrelated code while implementing a feature.
- If a refactor is necessary, keep it tightly scoped to the task.
- Preserve public behavior unless the task explicitly changes it.

## Communication in task summaries
At the end of the task, report:
- files changed
- key decisions
- tests run
- known limitations
- suggested next steps only if genuinely useful

## Good defaults
If the task is ambiguous, prefer:
- smaller change
- clearer code
- preserving current behavior
- native rendering over fragile HTML tricks
