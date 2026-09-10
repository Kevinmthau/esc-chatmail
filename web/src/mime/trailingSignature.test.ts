import { expect, it } from 'vitest'
import { processChatBubbleText } from './bubble'
import { removeTrailingContactSignature } from './signature'

it('preserves signature-like text inside a diagram after DOM cleanup', () => {
  const html = `<p>Project organization:</p><svg><text>Best,</text>
<text>John Smith</text>
<text>Partner</text>
<text>john@example.test</text>
<text>415-555-1212</text></svg>`
  const result = processChatBubbleText(html, { inputKind: 'html' })
  expect(result.mainText?.replace(/\s+/g, ' ').trim()).toBe(
    'Project organization: Best, John Smith Partner john@example.test 415-555-1212',
  )
})

it.each([
  'Design Reference\nhttps://example.com/one\nhttps://example.com/two',
  'Emergency Contacts\nEmergency line: 212-555-1234\nCustomer service line: 212-555-5678',
])('preserves a resource list without a sign-off: %s', (resources) => {
  const text = `Please keep these handy.\n${resources}`
  expect(removeTrailingContactSignature(text)).toBe(text)
})

it.each([
  'The contract is ready.',
  'You can reach the contractor here:',
  'Here is her information:',
  'Here is the plumber I recommend.',
])('preserves a titled contact block without a sign-off: %s', (introduction) => {
  const text = `${introduction}\nJohn Smith\nPartner\njohn@example.com\n404-555-0142`
  expect(removeTrailingContactSignature(text)).toBe(text)
})

it.each(['Market Street is closed', 'Meet on Market Street tomorrow', 'Drive Carefully'])(
  'preserves address-keyword prose before or after contacts: %s',
  (instruction) => {
    const signature = 'John Smith\nPartner\njohn@example.com\n404-555-0142'
    const trailingInstruction = `The contract is ready.\nBest,\n${signature}\n${instruction}`
    expect(removeTrailingContactSignature(trailingInstruction)).toBe(trailingInstruction)
    const precedingInstruction = `The contract is ready.\nBest,\n${instruction}\n${signature}`
    expect(removeTrailingContactSignature(precedingInstruction)).toBe(precedingInstruction)
  },
)

// Revert-check: contact-only second-pass thresholds, body stop and required sign-off / Swift twin.
const cases = [
  [
    'email_instruction',
    'Please review the plan.\nJane Doe\nPartner\njane@example.com\n415-555-1212\nPlease send the revised plan to bob@example.com.',
    'Please review the plan.\nJane Doe\nPartner\njane@example.com\n415-555-1212\nPlease send the revised plan to bob@example.com.',
  ],
  [
    'url_instruction',
    'Please review the plan.\nJane Doe\nPartner\njane@example.com\n415-555-1212\nPlease review the revised plan at https://example.com/plan.',
    'Please review the plan.\nJane Doe\nPartner\njane@example.com\n415-555-1212\nPlease review the revised plan at https://example.com/plan.',
  ],
  [
    'title_instruction',
    'Please review the plan.\nJane Doe\nPartner\njane@example.com\n415-555-1212\nThe manager will call tomorrow.',
    'Please review the plan.\nJane Doe\nPartner\njane@example.com\n415-555-1212\nThe manager will call tomorrow.',
  ],

  [
    'role_after_signoff',
    'The contract is ready.\n\nSincerely,\nPartner\njane@example.com\n404-555-0142',
    'The contract is ready.',
  ],
  [
    'titled_contact_only_document',
    'Jordan Smith\nPartner\njordan@example.com\n404-555-0142',
    'Jordan Smith\nPartner\njordan@example.com\n404-555-0142',
  ],

  [
    'contact_only_document',
    'Jane Doe\njane@example.com\n404-555-0142',
    'Jane Doe\njane@example.com\n404-555-0142',
  ],
  [
    'corporate_contact_tail',
    'The repair is scheduled.\n\nBest,\nJohn Boga\nProperty Manager\nOffice: 914-564-1325 | Monday - Friday | 9am - 5pm\nEmergency line after hours: 914-373-4658\nwww.nycbrownstone.net',
    'The repair is scheduled.\n\nBest,\nJohn Boga',
  ],
  [
    'minimal_two_contacts',
    'The contract is ready.\n\nSincerely,\nMarcita Threash\nmarcita@example.com\n404-555-0142',
    'The contract is ready.\n\nSincerely,\nMarcita Threash',
  ],
  [
    'contact_without_signoff',
    'The contract is ready.\n\nMarcita Threash\nmarcita@example.com\n404-555-0142',
    'The contract is ready.\n\nMarcita Threash\nmarcita@example.com\n404-555-0142',
  ],
  [
    'one_contact_below_name',
    'The contract is ready.\n\nBest,\nJane Doe\njane@example.com',
    'The contract is ready.\n\nBest,\nJane Doe\njane@example.com',
  ],
  [
    'two_contacts_without_name',
    'The contract is ready.\n\njane@example.com\n404-555-0142',
    'The contract is ready.\n\njane@example.com\n404-555-0142',
  ],
  [
    'contact_list_with_title',
    'Here are the reviewer contacts:\nJane Doe\nAccount Manager\njane@example.com\n404-555-0142',
    'Here are the reviewer contacts:\nJane Doe\nAccount Manager\njane@example.com\n404-555-0142',
  ],
  [
    'two_email_contact_list',
    'Please email both reviewers:\nAlice Smith\nalice@example.com\nBob Jones\nbob@example.com',
    'Please email both reviewers:\nAlice Smith\nalice@example.com\nBob Jones\nbob@example.com',
  ],
  [
    'contact_block_then_body',
    'Please contact our manager:\nJane Doe\nProperty Manager\njane@example.com\n404-555-0142\n\nPlease copy me on the reply.',
    'Please contact our manager:\nJane Doe\nProperty Manager\njane@example.com\n404-555-0142\n\nPlease copy me on the reply.',
  ],
  [
    'body_after_legal_words',
    'The document is ready.\n\nUnsubscribe from these notifications.\n\nOur privacy policy changed.\n\n© 2026 appears on the cover.\n\nPlease review the terms.',
    'The document is ready.\n\nUnsubscribe from these notifications.\n\nOur privacy policy changed.\n\n© 2026 appears on the cover.\n\nPlease review the terms.',
  ],
  [
    'contact_list_then_signoff',
    'Here are the reviewer contacts:\n- Jane at jane@example.com\n- John at john@example.com\n\nThanks,\nKevin',
    'Here are the reviewer contacts:\n- Jane at jane@example.com\n- John at john@example.com\n\nThanks,\nKevin',
  ],
] as const

it.each(cases)('%s', (_name, input, expected) => {
  expect(removeTrailingContactSignature(input)).toBe(expected)
})
