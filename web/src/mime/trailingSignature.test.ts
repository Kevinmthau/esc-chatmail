import { expect, it } from 'vitest'
import { removeTrailingContactSignature } from './signature'

// Revert-check: contact-only second-pass thresholds, body stop and intro veto / Swift twin.
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
    'The contract is ready.',
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
