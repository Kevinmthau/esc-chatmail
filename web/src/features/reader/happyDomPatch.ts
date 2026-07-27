// TEST-ONLY environment patches (imported by this module's vitest suites;
// never by app code). They fix two places where happy-dom diverges from
// browser DOM semantics that DOMPurify depends on. Both patches bring the
// test environment CLOSER to real browsers — they never weaken what the
// sanitizer tests assert. Must run before DOMPurify's module initializes
// (it caches `document.createNodeIterator` and Node.prototype getters).
//
// 1. nodeName: browsers define the `nodeName` getter once on Node.prototype
//    and it works for every node type. happy-dom overrides it per subclass
//    (Element, Text, ...) and its Node.prototype getter returns ''. DOMPurify
//    calls the cached Node.prototype getter with elements as receiver, so
//    every tag reads as '' and the allowlist rejects even <html>.
//
// 2. createNodeIterator: the spec requires a NodeIterator to adjust its
//    reference position when the current node is removed from the tree
//    ("pre-removing steps"). happy-dom's NodeIterator wraps a TreeWalker with
//    no such adjustment, so DOMPurify's walk silently STOPS at the first
//    removed node, leaving the rest of the document unsanitized (in tests
//    only — real browsers implement the spec). The replacement is a minimal
//    live pre-order iterator with spec-like removal recovery.

export function patchHappyDomForDomPurify(): void {
  patchNodeName()
  patchCreateNodeIterator()
}

/**
 * happy-dom registers window-scoped copies of the DOM classes, so the global
 * `Document.prototype` / `Node.prototype` are NOT necessarily in a live
 * node's prototype chain. Always locate the owning prototype by walking the
 * actual instance's chain.
 */
function protoOwning(instance: object, prop: string): object | null {
  let current: object | null = Object.getPrototypeOf(instance) as object | null
  while (current !== null) {
    if (Object.prototype.hasOwnProperty.call(current, prop)) return current
    current = Object.getPrototypeOf(current) as object | null
  }
  return null
}

function patchNodeName(): void {
  // A fragment's nodeName getter lives on the base Node prototype (happy-dom
  // subclasses override it for Element/Text/Comment/Document).
  const proto = protoOwning(document.createDocumentFragment(), 'nodeName')
  if (proto === null) return
  const descriptor = Object.getOwnPropertyDescriptor(proto, 'nodeName')
  // eslint-disable-next-line @typescript-eslint/unbound-method -- always invoked via .call(node)
  const original = descriptor?.get
  if (descriptor === undefined || original === undefined) return

  // Probe: in a compliant environment the Node.prototype getter already works
  // for elements and no patch is needed.
  const probe = document.createElement('nodename-probe')
  if ((original.call(probe) as string).toLowerCase() === 'nodename-probe') return

  function patchedGet(this: Node): string {
    let current: object | null = Object.getPrototypeOf(this) as object | null
    while (current !== null) {
      const own = Object.getOwnPropertyDescriptor(current, 'nodeName')
      if (own?.get !== undefined && own.get !== patchedGet) {
        return own.get.call(this) as string
      }
      current = Object.getPrototypeOf(current) as object | null
    }
    return original!.call(this) as string
  }

  Object.defineProperty(proto, 'nodeName', { ...descriptor, get: patchedGet })
}

/**
 * Live pre-order iterator over `root`'s tree. When the last returned node has
 * been removed, iteration resumes from the position just after the removed
 * node's recorded previous sibling (or at its parent's first child) — the
 * behavior the DOM spec's pre-removing steps produce for NodeIterator. That
 * also means nodes hoisted in place of a removed node ARE visited, exactly as
 * in a browser.
 */
class PreOrderNodeIterator {
  private ref: Node | null = null
  private anchorParent: Node | null = null
  private anchorPrev: Node | null = null

  constructor(
    private readonly root: Node,
    private readonly whatToShow: number,
  ) {}

  private accepts(node: Node): boolean {
    return (this.whatToShow & (1 << (node.nodeType - 1))) !== 0
  }

  private inTree(node: Node): boolean {
    return node === this.root || this.root.contains(node)
  }

  private successor(node: Node, skipChildren: boolean): Node | null {
    if (!skipChildren && node.firstChild !== null) return node.firstChild
    let current: Node | null = node
    while (current !== null && current !== this.root) {
      if (current.nextSibling !== null) return current.nextSibling
      current = current.parentNode
    }
    return null
  }

  nextNode(): Node | null {
    let candidate: Node | null
    if (this.ref === null) {
      candidate = this.root
    } else if (this.inTree(this.ref)) {
      candidate = this.successor(this.ref, false)
    } else if (this.anchorPrev !== null && this.inTree(this.anchorPrev)) {
      // The previous sibling's subtree was already fully visited; continue
      // with whatever now follows it (hoisted children or the old sibling).
      candidate = this.anchorPrev.nextSibling ?? this.successor(this.anchorPrev, true)
    } else if (this.anchorParent !== null && this.inTree(this.anchorParent)) {
      candidate = this.anchorParent.firstChild ?? this.successor(this.anchorParent, true)
    } else {
      return null
    }

    // whatToShow skips a node but still descends into its children.
    while (candidate !== null && !this.accepts(candidate)) {
      candidate = this.successor(candidate, false)
    }

    if (candidate !== null) {
      this.ref = candidate
      this.anchorParent = candidate.parentNode
      this.anchorPrev = candidate.previousSibling
    }
    return candidate
  }
}

function patchCreateNodeIterator(): void {
  const owner = protoOwning(document, 'createNodeIterator')
  if (owner === null) return
  const docProto = owner as Record<string, unknown>
  const marker = '__escReaderNodeIteratorPatched'
  if (docProto[marker] === true) return
  docProto[marker] = true
  docProto['createNodeIterator'] = function (
    this: Document,
    root: Node,
    whatToShow = 0xffffffff,
  ): unknown {
    return new PreOrderNodeIterator(root, whatToShow)
  }
}
