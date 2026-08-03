import { cleanup, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'

// Vitest globals are off, so RTL cannot register its own auto-cleanup.
afterEach(cleanup)
import { EMAIL_NATURAL_WIDTH, PREVIEW_HEIGHT_DEFAULT } from '@/lib/constants'
import { EmailFrame } from './EmailFrame'

function mockContentWindow(iframe: HTMLIFrameElement) {
  const postMessage = vi.fn()
  Object.defineProperty(iframe, 'contentWindow', {
    value: { postMessage },
    configurable: true,
  })
  return postMessage
}

describe('EmailFrame', () => {
  it('posts the render payload to the frame after load', async () => {
    const cidBlobs = { 'logo@example': new Blob(['x'], { type: 'image/png' }) }
    render(<EmailFrame html="<p>hi</p>" cidBlobs={cidBlobs} mode="full" />)

    const iframe = screen.getByTitle<HTMLIFrameElement>('Email content')
    const postMessage = mockContentWindow(iframe)
    iframe.dispatchEvent(new Event('load'))

    await waitFor(() => {
      expect(postMessage).toHaveBeenCalledWith({ type: 'render', html: '<p>hi</p>', cidBlobs }, '*')
    })
  })

  it('re-posts when the html changes', async () => {
    const { rerender } = render(<EmailFrame html="<p>one</p>" cidBlobs={{}} mode="full" />)
    const iframe = screen.getByTitle<HTMLIFrameElement>('Email content')
    const postMessage = mockContentWindow(iframe)
    iframe.dispatchEvent(new Event('load'))
    await waitFor(() => expect(postMessage).toHaveBeenCalledTimes(1))

    rerender(<EmailFrame html="<p>two</p>" cidBlobs={{}} mode="full" />)
    await waitFor(() => {
      expect(postMessage).toHaveBeenLastCalledWith(
        { type: 'render', html: '<p>two</p>', cidBlobs: {} },
        '*',
      )
    })
  })

  it('does not post before the frame has loaded', () => {
    render(<EmailFrame html="<p>hi</p>" cidBlobs={{}} mode="full" />)
    const iframe = screen.getByTitle<HTMLIFrameElement>('Email content')
    const postMessage = mockContentWindow(iframe)
    expect(postMessage).not.toHaveBeenCalled()
  })

  it('hardens the iframe: sandbox without allow-same-origin, no referrer', () => {
    render(<EmailFrame html="" cidBlobs={{}} mode="full" />)
    const iframe = screen.getByTitle<HTMLIFrameElement>('Email content')
    expect(iframe.getAttribute('src')).toBe('/email-frame.html')
    expect(iframe.getAttribute('sandbox')).toBe(
      'allow-scripts allow-popups allow-popups-to-escape-sandbox',
    )
    expect(iframe.getAttribute('sandbox')).not.toContain('allow-same-origin')
    expect(iframe.getAttribute('referrerpolicy')).toBe('no-referrer')
  })

  it('preview mode renders the scaled, non-interactive wrapper', () => {
    render(<EmailFrame html="<p>hi</p>" cidBlobs={{}} mode="preview" />)
    const iframe = screen.getByTitle<HTMLIFrameElement>('Email content')
    expect(iframe.style.width).toBe(`${EMAIL_NATURAL_WIDTH}px`)
    expect(iframe.style.transformOrigin).toBe('top left')
    expect(iframe.style.pointerEvents).toBe('none')

    const wrapper = iframe.parentElement
    expect(wrapper).not.toBeNull()
    expect(wrapper?.style.height).toBe(`${PREVIEW_HEIGHT_DEFAULT}px`)
    expect(wrapper?.className).toContain('overflow-hidden')
  })

  it('full mode fills its container', () => {
    render(<EmailFrame html="<p>hi</p>" cidBlobs={{}} mode="full" />)
    const iframe = screen.getByTitle<HTMLIFrameElement>('Email content')
    expect(iframe.className).toContain('h-full')
    expect(iframe.className).toContain('w-full')
  })
})
