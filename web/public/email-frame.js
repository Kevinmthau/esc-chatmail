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

  function rewriteCidImages(doc, urlByCid) {
    var images = doc.querySelectorAll('img')
    for (var i = 0; i < images.length; i++) {
      var src = images[i].getAttribute('src') || ''
      if (src.slice(0, 4).toLowerCase() !== 'cid:') continue
      var cid = src.slice(4).replace(/[<>]/g, '').trim()
      var mapped = urlByCid[cid]
      if (mapped) {
        images[i].setAttribute('src', mapped)
      } else {
        // Unresolvable inline image — drop the src so nothing dangles.
        images[i].removeAttribute('src')
      }
    }
  }

  function render(html, cidBlobs) {
    // Re-render: revoke the previous document's object URLs first.
    revokeActiveUrls()
    var urlByCid = mintObjectUrls(cidBlobs)

    var doc = new DOMParser().parseFromString(html, 'text/html')
    rewriteCidImages(doc, urlByCid)

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
