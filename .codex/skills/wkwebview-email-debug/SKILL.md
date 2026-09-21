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
   - Full message: `EmailReaderView` -> `FullEmailReaderView` -> `HTMLMessageView` in `esc-chatmail/Views/Chat/`, then `HTMLWebView` (`esc-chatmail/Views/Components/EmailContent/HTMLFullWebView.swift`) -> `FullEmailReaderWebView.swift`
   - Chat preview: `esc-chatmail/Views/Components/EmailContent/EmailContentSection.swift` uses `esc-chatmail/Services/Preview/EmailPreviewPipeline.swift` to select native cards or `EmailPreviewSnapshotView.swift`
   - Snapshot failure fallback: `MiniEmailWebView.swift` -> `BaseEmailWebView` in `.scaledPreview`; compose HTML previews use `.simplePreview`

2. Trace content generation separately from WebKit.
   - Source selection and recovery: `OriginalEmailSourceLoader.swift`, `HTMLContentLoader.swift`, `HTMLContentHandler.swift`, and `HTMLContentRecoveryService.swift` in `esc-chatmail/Services/HTMLContent/`; `esc-chatmail/Services/Preview/EmailPreviewSourceLoader.swift` owns preview source loading
   - Sanitization and wrapping: `esc-chatmail/Services/HTMLSanitization/HTMLSanitizerService.swift`, `esc-chatmail/Services/HTMLSanitization/HTMLDisplayWrapper.swift`
   - Remote image fixes: `esc-chatmail/Services/HTMLSanitization/HTMLRemoteImageAttachmentFallback.swift`
   - Preview routing/model generation: `EmailPreviewPipeline.swift`, `EmailPreviewClassifier.swift`, and the native preview builders in `esc-chatmail/Services/Preview/`

3. Trace the WKWebView lifecycle.
   - Full reader: `esc-chatmail/Views/Components/EmailContent/FullEmailReaderWebView.swift`; `esc-chatmail/Services/Chat/FullEmailWebViewManager.swift` owns prepared-content warming, shared full-reader settings, and policy-gated offscreen WebView adoption
   - Full-reader presentation: `FullEmailOpenSession` owns preparation state; `FullEmailReaderView` retains an available preview snapshot as a placeholder until the live WebView confirms paint
   - Snapshot previews: `esc-chatmail/Services/Preview/EmailPreviewSnapshotRenderer.swift` and `EmailPreviewSnapshotCache.swift`; `EmailPreviewSnapshotView` displays the cached image and falls back to a live preview on failure
   - Live fallback and compose previews: `esc-chatmail/Views/Components/EmailContent/BaseEmailWebView.swift`
   - Inline attachment loading: `esc-chatmail/Services/Attachments/CIDSchemeHandler.swift`
   - Prewarm behavior: `AppPrewarmer` in `esc-chatmail/Services/HTMLContent/WebKitPrewarmer.swift`
   - Check surface-specific settings: JavaScript, data detectors, base URL, user agent, and navigation policy. Full original emails force light appearance; preview surfaces follow app appearance.

4. Trace sizing and measurement independently.
   - Snapshot measurement and capture: `EmailPreviewSnapshotRenderSession.measureRenderedHeight` and `snapshot` in `EmailPreviewSnapshotRenderer.swift`, with clamped display height published by `EmailPreviewSnapshotViewModel`
   - Preview scaling heuristics: `esc-chatmail/Views/Components/EmailContent/HTMLPreviewScaleCalculator.swift`
   - Live fallback height clamping: `MiniEmailWebView.swift`
   - Live fallback delayed measurements: `BaseEmailWebView.Coordinator.schedulePreviewHeightMeasurement` and `measurePreviewHeight`

5. Use the repo's failure patterns.
   - Double sanitization can corrupt complex newsletter HTML.
   - Wrapping a full HTML document inside another HTML shell can yield blank or partial previews.
   - Preview scale CSS must never leak into the full-message path.
   - Missing `message` context breaks `cid:` inline attachments.
   - Wrong or missing base URL can break CDN-hosted remote images that check `Referer`.
   - WKWebView may advertise support for image formats that still need `HTMLRemoteImageAttachmentFallback`.
   - Snapshot and live fallback measurements may need to settle after `didFinish` because assets continue loading.

6. Reproduce with the smallest useful tool.
   - Full-reader lifecycle: `FullEmailReaderWebViewTests`, `FullEmailWebViewManagerPreparedPayloadEvictionTests`, `FullEmailWebViewAdoptionPolicyTests`, `FullEmailReaderCoordinatorTests`
   - Preview routing and sizing: `EmailPreviewPipelineTests`, `EmailContentSectionTests`, `EmailPreviewSnapshotCacheTests`, `HTMLPreviewScaleCalculatorTests`
   - Source/sanitization: `HTMLContentLoaderTests`, `HTMLDisplayWrapperTests`, `HTMLSanitizerServiceTests`, `HTMLRemoteImageAttachmentFallbackTests`
   - Manual debug aid if needed: `esc-chatmail/Views/Components/EmailContent/HTMLRenderingDebugView.swift`

7. Fix the lowest layer that explains the symptom.
   - Content generation bug: patch loader/sanitizer/wrapper
   - Lifecycle bug: patch the owning full-reader, snapshot renderer, or live-preview coordinator/configuration
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
