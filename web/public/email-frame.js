// Email viewer frame script. Runs inside the sandboxed, opaque-origin
// email-frame.html document.
//
// Trust model
// -----------
// The HTML arriving here has ALREADY been sanitized by the parent app
// (DOMPurify in sanitizeEmailHtml); this document's CSP and the iframe
// sandbox are defense in depth, not the primary defense.
//
// Because this frame is sandboxed without allow-same-origin, its own origin
// is opaque and the parent must post with targetOrigin '*'. From in here,
// event.origin reports the embedding page's origin — a value this static
// file cannot know at build time. So instead of an origin check, we lock
// onto the first window that posts a well-formed render message (only the
// embedding parent can reach a freshly created frame before anyone else)
// and ignore every other source afterwards.
//
// cid images: object URLs are origin-bound. URLs minted by the parent are
// NOT fetchable from this opaque origin, which is why the parent
// structured-clones the Blobs in and this script mints object URLs locally.
;(function () {
  'use strict'

  var trustedSource = null
  var activeObjectUrls = []

  function revokeActiveUrls() {
    for (var i = 0; i < activeObjectUrls.length; i++) {
      URL.revokeObjectURL(activeObjectUrls[i])
    }
    activeObjectUrls = []
  }

  function isRenderMessage(data) {
    return !!data && data.type === 'render' && typeof data.html === 'string'
  }

  function mintObjectUrls(cidBlobs) {
    var urlByCid = Object.create(null)
    if (!cidBlobs || typeof cidBlobs !== 'object') return urlByCid
    for (var cid in cidBlobs) {
      if (!Object.prototype.hasOwnProperty.call(cidBlobs, cid)) continue
      if (!(cidBlobs[cid] instanceof Blob)) continue
      var url = URL.createObjectURL(cidBlobs[cid])
      urlByCid[cid] = url
      activeObjectUrls.push(url)
    }
    return urlByCid
  }

  function normalizeCid(rawCid) {
    return rawCid.replace(/[<>]/g, '').trim()
  }

  // url(cid:...) inside CSS text, quoted or bare. Keep in sync with
  // CSS_CID_URL_PATTERN in sanitizeEmailHtml.ts.
  var CSS_CID_URL_PATTERN = /url\(\s*(['"]?)cid:([^'")\s]*)\1\s*\)/gi

  // Rewrites one srcset candidate list. Returns null when no candidate is a
  // cid: URL (leave the attribute untouched); '' when every candidate was an
  // unresolved cid (remove the attribute, so a rewritten sibling src can win
  // instead of an empty srcset shadowing it); else the rebuilt list. Non-cid
  // pieces are kept verbatim and re-joined with ',' so a data: URI split
  // apart by the naive comma split round-trips intact.
  function rewriteSrcset(srcset, urlByCid) {
    var pieces = srcset.split(',')
    var kept = []
    var sawCid = false
    for (var i = 0; i < pieces.length; i++) {
      var candidate = pieces[i].trim()
      if (candidate.slice(0, 4).toLowerCase() !== 'cid:') {
        kept.push(pieces[i])
        continue
      }
      sawCid = true
      var parts = candidate.split(/\s+/)
      var mapped = urlByCid[normalizeCid(parts[0].slice(4))]
      if (!mapped) continue // unresolvable candidate — drop it
      parts[0] = mapped
      kept.push(parts.join(' '))
    }
    return sawCid ? kept.join(',') : null
  }

  function rewriteStyleCidUrls(style, urlByCid) {
    return style.replace(CSS_CID_URL_PATTERN, function (match, quote, rawCid) {
      var mapped = urlByCid[normalizeCid(rawCid)]
      // `none` keeps the declaration parseable (background/background-image
      // and friends all accept it) with nothing left dangling.
      return mapped ? 'url("' + mapped + '")' : 'none'
    })
  }

  function rewriteCidReferences(doc, urlByCid) {
    var images = doc.querySelectorAll('img')
    for (var i = 0; i < images.length; i++) {
      var src = images[i].getAttribute('src') || ''
      if (src.slice(0, 4).toLowerCase() !== 'cid:') continue
      var mapped = urlByCid[normalizeCid(src.slice(4))]
      if (mapped) {
        images[i].setAttribute('src', mapped)
      } else {
        // Unresolvable inline image — drop the src so nothing dangles.
        images[i].removeAttribute('src')
      }
    }

    var srcsetHosts = doc.querySelectorAll('[srcset]')
    for (i = 0; i < srcsetHosts.length; i++) {
      var srcset = rewriteSrcset(srcsetHosts[i].getAttribute('srcset') || '', urlByCid)
      if (srcset === null) continue
      if (srcset === '') srcsetHosts[i].removeAttribute('srcset')
      else srcsetHosts[i].setAttribute('srcset', srcset)
    }

    var backgroundHosts = doc.querySelectorAll('[background]')
    for (i = 0; i < backgroundHosts.length; i++) {
      var background = backgroundHosts[i].getAttribute('background') || ''
      if (background.slice(0, 4).toLowerCase() !== 'cid:') continue
      var mappedBackground = urlByCid[normalizeCid(background.slice(4))]
      if (mappedBackground) backgroundHosts[i].setAttribute('background', mappedBackground)
      else backgroundHosts[i].removeAttribute('background')
    }

    var styledHosts = doc.querySelectorAll('[style]')
    for (i = 0; i < styledHosts.length; i++) {
      var style = styledHosts[i].getAttribute('style') || ''
      if (style.toLowerCase().indexOf('cid:') === -1) continue
      styledHosts[i].setAttribute('style', rewriteStyleCidUrls(style, urlByCid))
    }
  }

  function render(html, cidBlobs) {
    // Re-render: revoke the previous document's object URLs first.
    revokeActiveUrls()
    var urlByCid = mintObjectUrls(cidBlobs)

    var doc = new DOMParser().parseFromString(html, 'text/html')
    rewriteCidReferences(doc, urlByCid)

    var incoming = doc.documentElement
      ? Array.prototype.slice.call(doc.documentElement.childNodes)
      : []
    var adopted = incoming.map(function (node) {
      return document.adoptNode(node)
    })
    // Replacing <head> does not un-apply the CSP baked into email-frame.html:
    // meta CSP is enforced from parse time for the document's lifetime.
    document.documentElement.replaceChildren.apply(document.documentElement, adopted)
  }

  window.addEventListener('message', function (event) {
    if (!isRenderMessage(event.data)) return
    if (trustedSource === null) {
      trustedSource = event.source
    } else if (event.source !== trustedSource) {
      return
    }
    render(event.data.html, event.data.cidBlobs)
  })
})()
