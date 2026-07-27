// Native-dialog lifecycle: a Modal that goes away while open — whether via the
// open prop or by being unmounted outright (router removed it, e.g. compose
// after a successful send) — must run close() and give focus back to the
// element that had it before the dialog opened. Browsers only restore focus on
// an explicit close(); removal from the DOM skips it.

import { cleanup, render } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { Modal } from './Modal'

let trigger: HTMLButtonElement

beforeEach(() => {
  trigger = document.createElement('button')
  trigger.textContent = 'open'
  document.body.appendChild(trigger)
  trigger.focus()
})

afterEach(() => {
  cleanup()
  trigger.remove()
})

function dialogOf(container: HTMLElement): HTMLDialogElement {
  const dialog = container.querySelector('dialog')
  if (dialog === null) throw new Error('no <dialog> rendered')
  return dialog
}

describe('Modal', () => {
  it('runs close() and restores focus when unmounted while open', () => {
    const view = render(
      <Modal open onClose={() => undefined} ariaLabel="Test dialog">
        <p>content</p>
      </Modal>,
    )
    const dialog = dialogOf(view.container)
    expect(dialog.open).toBe(true)
    const closeSpy = vi.spyOn(dialog, 'close')

    view.unmount()

    expect(closeSpy).toHaveBeenCalledTimes(1)
    expect(dialog.open).toBe(false)
    expect(document.activeElement).toBe(trigger)
  })

  it('closes and restores focus when the open prop turns false', () => {
    const view = render(
      <Modal open onClose={() => undefined} ariaLabel="Test dialog">
        <p>content</p>
      </Modal>,
    )
    const dialog = dialogOf(view.container)
    expect(dialog.open).toBe(true)

    view.rerender(
      <Modal open={false} onClose={() => undefined} ariaLabel="Test dialog">
        <p>content</p>
      </Modal>,
    )

    expect(dialog.open).toBe(false)
    expect(document.activeElement).toBe(trigger)
  })
})
