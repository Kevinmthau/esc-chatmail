---
name: wkwebview-email-debug
description: Debug esc-chatmail email rendering issues by separating HTML generation, WKWebView lifecycle, and preview sizing before making the smallest stabilizing fix.
---

# WKWebView Email Debug

## When To Use

Use when email previews or full-message views are blank, clipped, over-scaled, missing images, mis-sized, or otherwise unstable.

## Goal

Find the failing layer quickly, keep preview and full-message behavior separated, and land the smallest fix that stabilizes rendering.

## Workflow

1. Classify the surface first.
   - Full message: `esc-chatmail/Views/Chat/HTMLMessageView.swift`, `esc-chatmail/Views/Components/EmailContent/HTMLFullWebView.swift`, `BaseEmailWebView` in `.fullInteractive`
   - Chat preview: `esc-chatmail/Views/Components/EmailContent/EmailContentSection.swift`, `MiniEmailWebView.swift`, `HTMLPreviewWebView.swift`, `BaseEmailWebView` in preview modes

2. Trace content generation separately from WebKit.
   - Source selection and recovery: `esc-chatmail/Services/HTMLContentLoader.swift`, `HTMLContentHandler.swift`, `HTMLContentRecoveryService`
   - Sanitization and wrapping: `esc-chatmail/Services/HTMLSanitizerService.swift`, `esc-chatmail/Services/HTMLSanitization/HTMLDisplayWrapper.swift`
   - Remote image fixes: `esc-chatmail/Services/HTMLSanitization/HTMLRemoteImageAttachmentFallback.swift`
   - Preview routing/model generation: `EmailPreviewClassifier.swift`, `NewsletterPreviewBuilder.swift`, `TransactionalPreviewBuilder.swift`

3. Trace the WKWebView lifecycle.
   - Main view wrapper: `esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift`
   - Inline attachment loading: `esc-chatmail/Services/CIDSchemeHandler.swift`
   - Prewarm behavior: `esc-chatmail/Services/WebKitPrewarmer.swift`
   - Check mode-specific settings: JavaScript, data detectors, base URL, user agent, and navigation policy

4. Trace sizing and measurement independently.
   - Preview scaling heuristics: `esc-chatmail/Views/Components/EmailContent/HTMLPreviewScaleCalculator.swift`
   - Preview height clamping: `MiniEmailWebView.swift`
   - Delayed measurements: `BaseEmailWebView.schedulePreviewHeightMeasurements` and `measurePreviewHeight`

5. Use the repo's failure patterns.
   - Double sanitization can corrupt complex newsletter HTML.
   - Wrapping a full HTML document inside another HTML shell can yield blank or partial previews.
   - Preview scale CSS must never leak into the full-message path.
   - Missing `message` context breaks `cid:` inline attachments.
   - Wrong or missing base URL can break CDN-hosted remote images that check `Referer`.
   - WKWebView may advertise support for image formats that still need `HTMLRemoteImageAttachmentFallback`.
   - Preview height often needs multiple delayed measurements after `didFinish` because assets continue loading.

6. Reproduce with the smallest useful tool.
   - Unit tests first: `HTMLContentLoaderTests`, `HTMLDisplayWrapperTests`, `HTMLSanitizerServiceTests`, `HTMLRemoteImageAttachmentFallbackTests`, `HTMLPreviewScaleCalculatorTests`
   - Manual debug aid if needed: `esc-chatmail/Views/Components/EmailContent/HTMLRenderingDebugView.swift`

7. Fix the lowest layer that explains the symptom.
   - Content generation bug: patch loader/sanitizer/wrapper
   - Lifecycle bug: patch `BaseEmailWebView` mode/config/baseURL/navigation
   - Sizing bug: patch scale or measurement logic only

## Output Format

- `Symptom:` what is broken and where
- `Layer:` content generation, webview lifecycle, or sizing
- `Fix:` smallest change made or recommended
- `Validation:` exact tests run and any manual check used

## Guardrails

- Preserve full-message fidelity over preview convenience.
- Do not mutate canonical/original HTML just to make a chat preview look better.
- Do not route full-message rendering through the scaled-preview path.
- Avoid adding JavaScript or broad CSS rewrites if a smaller wrapper, URL, or measurement fix will solve it.
- Keep preview-specific transforms isolated to preview-only code paths.
