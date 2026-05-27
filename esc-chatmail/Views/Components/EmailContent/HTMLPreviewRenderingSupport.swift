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
