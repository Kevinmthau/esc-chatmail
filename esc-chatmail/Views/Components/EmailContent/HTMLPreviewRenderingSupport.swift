import Foundation
import SwiftUI

enum HTMLPreviewSizing {
    static let defaultPreviewHeight: CGFloat = 180
    static let minimumPreviewHeight: CGFloat = 120
    static let maximumPreviewHeight: CGFloat = 320

    static func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, minimumPreviewHeight), maximumPreviewHeight)
    }
}

enum HTMLPreviewScalingWrapper {
    static func wrap(_ html: String, scale: CGFloat) -> String {
        if html.range(of: "<!doctype", options: .caseInsensitive) != nil ||
            html.range(of: "<html", options: .caseInsensitive) != nil {
            return injectScaleStyles(into: html, scale: scale)
        }

        return wrapPartialHTMLWithScale(html, scale: scale)
    }

    private static func injectScaleStyles(into html: String, scale: CGFloat) -> String {
        let injected = """
        <style id="esc-preview-scale">
            html, body {
                overflow: hidden !important;
                min-height: 1px !important;
            }
            /* Use higher specificity + !important so template body rules don't override preview scaling. */
            html body {
                -webkit-text-size-adjust: 100% !important;
                transform: scale(\(scale)) !important;
                transform-origin: top left !important;
                width: \(100.0 / scale)% !important;
                min-width: 0 !important;
                min-height: 1px !important;
                display: block !important;
            }
            img { max-width: 100%; height: auto; }
            table { max-width: 100%; }
        </style>
        """

        if html.range(of: "id=\"esc-preview-scale\"", options: .caseInsensitive) != nil {
            return ensureDoctype(html)
        }

        var result = html

        if let headRange = result.range(of: "<head>", options: .caseInsensitive) {
            result.insert(contentsOf: "\n" + injected + "\n", at: headRange.upperBound)
            return ensureDoctype(result)
        }

        if let headStart = result.range(of: "<head", options: .caseInsensitive),
           let closing = result[headStart.lowerBound...].firstIndex(of: ">") {
            let insertIndex = result.index(after: closing)
            result.insert(contentsOf: "\n" + injected + "\n", at: insertIndex)
            return ensureDoctype(result)
        }

        if let htmlStart = result.range(of: "<html", options: .caseInsensitive),
           let closing = result[htmlStart.lowerBound...].firstIndex(of: ">") {
            let insertIndex = result.index(after: closing)
            result.insert(contentsOf: "\n<head>\n" + injected + "\n</head>\n", at: insertIndex)
            return ensureDoctype(result)
        }

        return wrapPartialHTMLWithScale(result, scale: scale)
    }

    private static func wrapPartialHTMLWithScale(_ html: String, scale: CGFloat) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <style>
                * { box-sizing: border-box; }
                html, body {
                    margin: 0;
                    padding: 0;
                    overflow: hidden;
                    -webkit-text-size-adjust: 100%;
                    min-height: 1px;
                }
                .scale-wrapper {
                    transform: scale(\(scale));
                    transform-origin: top left;
                    width: \(100.0 / scale)%;
                    min-height: 1px;
                    display: inline-block;
                }
                /* Only constrain, don't force widths */
                img { max-width: 100%; height: auto; }
                table { max-width: 100%; }
            </style>
        </head>
        <body>
            <div class="scale-wrapper">
                \(html)
            </div>
        </body>
        </html>
        """
    }

    private static func ensureDoctype(_ html: String) -> String {
        if html.range(of: "<!doctype", options: .caseInsensitive) != nil {
            return html
        }
        return "<!DOCTYPE html>\n" + html
    }
}

enum HTMLPreviewHeightMeasurementScript {
    static func script(scale: CGFloat) -> String {
        """
        (function() {
            var heights = [];
            function push(value) {
                if (typeof value === 'number' && isFinite(value) && value > 0) {
                    heights.push(value);
                }
            }

            var wrapper = document.querySelector('.scale-wrapper');
            if (wrapper) {
                push(wrapper.getBoundingClientRect().height);
                push(wrapper.scrollHeight * \(scale));
                push(wrapper.offsetHeight * \(scale));
            }

            if (document.body) {
                push(document.body.getBoundingClientRect().height);
                push(document.body.scrollHeight * \(scale));
                push(document.body.offsetHeight * \(scale));
            }

            if (document.documentElement) {
                push(document.documentElement.getBoundingClientRect().height);
                push(document.documentElement.scrollHeight * \(scale));
                push(document.documentElement.offsetHeight * \(scale));
            }

            return heights.length ? Math.ceil(Math.max.apply(null, heights)) : 0;
        })();
        """
    }
}

/// Reports the images a snapshot would capture (architecture review 2026-11,
/// `web-content-rendering#3`): the ones that did not load, broken (`naturalWidth` 0 once complete)
/// or not complete yet, and the `cid:` source of every one, loaded or not. Only images that show in
/// the capture area are reported: with a `src` (lazy-loader markup with only `data-src` asks for
/// nothing), larger than 2×2 points once clipped by any ancestor that clips (tracking pixels and
/// spacers, which a dead tracker host leaves broken for good, would otherwise keep a card from ever
/// being stored), with no ancestor of opacity 0, not hidden, and inside the first `captureHeight`
/// points of the view at its `captureWidth`. An image that did not load is reported as
/// `scheme://host/` for http(s), which is all `HTMLPreviewSnapshotImageOutcome` needs to know
/// whether it was blocked on purpose, and as its scheme otherwise (a `data:` URL can be megabytes).
/// A `cid:` image the app could not supply loads as the scheme handler's transparent stand-in, so
/// it is not among those; its source is reported so that `CIDSchemeHandler`'s record of it counts
/// only if it is in the capture. Each list holds at most 256 entries, past which the outcome is
/// truncated and reads as incomplete.
enum HTMLPreviewSnapshotImageOutcomeScript {
    static func script(captureWidth: CGFloat, captureHeight: CGFloat) -> String {
        """
        (function(captureWidth, captureHeight) {
            var limit = 256;
            var outcome = { incomplete: [], cids: [], truncated: false };
            function push(list, value) {
                if (list.length >= limit) { outcome.truncated = true; return; }
                list.push(value);
            }
            function schemeOf(source) {
                var colon = source.indexOf(':');
                return colon < 0 ? '' : source.slice(0, colon + 1).toLowerCase();
            }
            var images = document.images;
            for (var i = 0; i < images.length; i++) {
                var image = images[i];
                if (!image.getAttribute('src') && !image.currentSrc) { continue; }
                var style = window.getComputedStyle(image);
                if (style.visibility === 'hidden' || style.display === 'none') { continue; }
                var rect = image.getBoundingClientRect();
                var left = rect.left, top = rect.top, right = rect.right, bottom = rect.bottom;
                var transparent = false;
                for (var node = image; node && node.nodeType === 1; node = node.parentElement) {
                    var nodeStyle = node === image ? style : window.getComputedStyle(node);
                    if (parseFloat(nodeStyle.opacity) === 0) { transparent = true; break; }
                    if (node === image) { continue; }
                    if (nodeStyle.overflowX !== 'visible' || nodeStyle.overflowY !== 'visible') {
                        var clip = node.getBoundingClientRect();
                        if (nodeStyle.overflowX !== 'visible') {
                            left = Math.max(left, clip.left);
                            right = Math.min(right, clip.right);
                        }
                        if (nodeStyle.overflowY !== 'visible') {
                            top = Math.max(top, clip.top);
                            bottom = Math.min(bottom, clip.bottom);
                        }
                    }
                }
                if (transparent) { continue; }
                if (right - left <= 2 || bottom - top <= 2) { continue; }
                if (bottom <= 0 || top >= captureHeight) { continue; }
                if (right <= 0 || left >= captureWidth) { continue; }
                var source = image.currentSrc || image.src;
                var scheme = schemeOf(source);
                if (scheme === 'cid:') { push(outcome.cids, source.length <= 2048 ? source : 'cid:'); }
                if (image.complete && image.naturalWidth !== 0) { continue; }
                if (scheme === 'http:' || scheme === 'https:') {
                    var origin = scheme + '//';
                    try { origin = scheme + '//' + new URL(source).host + '/'; } catch (error) {}
                    push(outcome.incomplete, origin);
                } else {
                    push(outcome.incomplete, scheme);
                }
            }
            return outcome;
        })(\(Int(captureWidth.rounded())), \(Int(captureHeight.rounded())));
        """
    }
}

/// What `HTMLPreviewSnapshotImageOutcomeScript` found, and whether it makes the capture complete.
struct HTMLPreviewSnapshotImageOutcome: Equatable, Sendable {
    /// One entry for each image in the capture that did not load: `scheme://host/` for http(s),
    /// its scheme otherwise.
    let incompleteSources: [String]
    /// The `cid:` source of each image in the capture, loaded or not.
    let capturedCIDSources: [String]
    /// A list reached the script's limit, so the outcome is not known whole.
    let isTruncated: Bool

    init(incompleteSources: [String], capturedCIDSources: [String], isTruncated: Bool) {
        self.incompleteSources = incompleteSources
        self.capturedCIDSources = capturedCIDSources
        self.isTruncated = isTruncated
    }

    /// Reads the script's result; nil for anything else, which the caller reads as incomplete.
    init?(scriptResult: Any?) {
        guard let dictionary = scriptResult as? [String: Any],
              let incomplete = dictionary["incomplete"] as? [String],
              let cids = dictionary["cids"] as? [String] else {
            return nil
        }
        self.init(
            incompleteSources: incomplete,
            capturedCIDSources: cids,
            isTruncated: (dictionary["truncated"] as? Bool) ?? true
        )
    }

    /// Whether an image that did not load was refused on purpose: a load of a private, loopback,
    /// link-local, single-label or otherwise reserved host, which the web content rules refuse
    /// (`EmailWebContentNetworkRuleSource`, built from the same `PrivateNetworkAddressDetector`).
    /// Such an image will not load at any later render, so counting it kept the card off disk for
    /// good and rendered it again every ten minutes: a NAS or router notification, or any mail with
    /// an image on such a host. Any other blocking of image loads in the snapshot web view (an
    /// image-consent gate, say) must be answered here too, or every card it blocks is incomplete.
    static func isBlockedOnPurpose(_ source: String) -> Bool {
        guard let url = URL(string: source),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return false
        }
        return PrivateNetworkAddressDetector.isPrivateOrReserved(url)
    }

    /// Complete when every image in the capture that did not load was blocked on purpose and no
    /// `cid:` image in the capture is one the scheme handler could not supply for now
    /// (`CIDSchemeHandler.unavailableContentIDs`).
    func isComplete(unavailableContentIDs: Set<String>) -> Bool {
        guard !isTruncated else { return false }
        if incompleteSources.contains(where: { !Self.isBlockedOnPurpose($0) }) {
            return false
        }
        return !capturedCIDSources.contains { source in
            guard let contentID = CIDSchemeHandler.normalizedContentID(fromSource: source) else {
                return false
            }
            return unavailableContentIDs.contains(contentID)
        }
    }
}

enum HTMLPreviewSnapshotHeightMeasurementScript {
    static func script(scale: CGFloat) -> String {
        """
        (function() {
            var heights = [];
            function push(value) {
                if (typeof value === 'number' && isFinite(value) && value > 0) {
                    heights.push(value);
                }
            }

            var wrapper = document.querySelector('.scale-wrapper');
            if (wrapper) {
                push(wrapper.getBoundingClientRect().height);
                push(wrapper.scrollHeight * \(scale));
                push(wrapper.offsetHeight * \(scale));
            }

            function pushContentBounds(root) {
                if (!root) { return; }

                var rootRect = root.getBoundingClientRect();
                var range = document.createRange();
                range.selectNodeContents(root);
                var rects = range.getClientRects();
                for (var i = 0; i < rects.length; i++) {
                    push(rects[i].bottom - rootRect.top);
                }

                var elements = root.querySelectorAll('*');
                for (var j = 0; j < elements.length; j++) {
                    var rect = elements[j].getBoundingClientRect();
                    if (rect.width > 0 || rect.height > 0) {
                        push(rect.bottom - rootRect.top);
                    }
                }
            }

            pushContentBounds(document.body);

            return heights.length ? Math.ceil(Math.max.apply(null, heights)) : 0;
        })();
        """
    }
}
