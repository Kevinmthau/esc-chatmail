import { describe, expect, it } from 'vitest'
import { removeSignature } from './signature'
import { unwrapEmailLineBreaks } from './text'

// Revert-check: signature.ts contact-prefix, anchored-tail and sign-off policy / Swift PlainTextSignatureRemover.
// HONEST SCOPE: mobile/legal/wire cases are existing removal controls.
const cases = [
  [
    'title_prose',
    'Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nThe manager will call tomorrow.',
    'Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nThe manager will call tomorrow.',
  ],
  [
    'email_prose',
    'Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease send the revised plan to bob@example.com.',
    'Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease send the revised plan to bob@example.com.',
  ],
  [
    'url_prose',
    'Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease review the revised plan at https://example.com/plan.',
    'Please review the plan.\n\nCONFIDENTIALITY NOTICE: This email is confidential.\n\nPlease review the revised plan at https://example.com/plan.',
  ],
  [
    'authored_tagline_body_sentence',
    'Please review the plan.\n\nThe homeowner will coordinate with the broker.\nThe estimate changed.\n415-555-1212\njane@example.com',
    'Please review the plan.\n\nThe homeowner will coordinate with the broker.\nThe estimate changed.\n415-555-1212\njane@example.com',
  ],
  [
    'authored_tagline_personal_name',
    'Please review the plan.\n\nJane Doe\nThe estimate changed.\n415-555-1212\njane@example.com',
    'Please review the plan.\n\nJane Doe\nThe estimate changed.\n415-555-1212\njane@example.com',
  ],
  [
    'body_before_legal_footer',
    'The manager will call tomorrow.\n\nThis email and any attachments are confidential.',
    'The manager will call tomorrow.',
  ],

  [
    'legal_words_in_body',
    'Confidentiality notice: we need to discuss this.\n\nThe account is ready for review.\n\nOur services launch on Monday.',
    'Confidentiality notice: we need to discuss this.\n\nThe account is ready for review.\n\nOur services launch on Monday.',
  ],
  [
    'body_after_legal_footer',
    'The document is attached.\n\nThis email and any attachments are confidential.\n\nThe account is ready and the terms are final.\n\nPlease review our services before Monday.',
    'The document is attached.\n\nThis email and any attachments are confidential.\n\nThe account is ready and the terms are final.\n\nPlease review our services before Monday.',
  ],
  [
    'titled_contact_list',
    'Here are the contacts:\n- Jane Doe — Account Manager — jane@example.com\n- John Roe — Sales Director — john@example.com\nhttps://example.com/team',
    'Here are the contacts:\n- Jane Doe — Account Manager — jane@example.com\n- John Roe — Sales Director — john@example.com\nhttps://example.com/team',
  ],

  [
    'descriptive_phone_signature',
    'The repair is scheduled.\n\nBest,\nJohn Boga\nProperty Manager\nEmergency line after hours: 914-373-4658\nwww.nycbrownstone.net',
    'The repair is scheduled.\n\nBest,\nJohn Boga',
  ],
  [
    'body_mobile-first',
    'Hi team,\n\nThe review is complete.\n\nMobile-first design is the priority for this release.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nMobile-first design is the priority for this release.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'body_m',
    'Hi team,\n\nThe review is complete.\n\nM. Smith will join us tomorrow.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nM. Smith will join us tomorrow.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'body_o-rings',
    'Hi team,\n\nThe review is complete.\n\nO-rings are back in stock.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nO-rings are back in stock.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'body_f-150',
    'Hi team,\n\nThe review is complete.\n\nF-150 is in the shop this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nF-150 is in the shop this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'body_d',
    'Hi team,\n\nThe review is complete.\n\nD. Wong signed off on the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nD. Wong signed off on the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'body_important',
    'Hi team,\n\nThe review is complete.\n\nImportant: the deadline moved to Monday.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nImportant: the deadline moved to Monday.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'body_you',
    'Hi team,\n\nThe review is complete.\n\nYou are receiving this because we need your input.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nYou are receiving this because we need your input.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'body_our',
    'Hi team,\n\nThe review is complete.\n\nOur privacy policy changed this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
    'Hi team,\n\nThe review is complete.\n\nOur privacy policy changed this week.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.',
  ],
  [
    'orphan_postscript',
    'The delivery is confirmed.\n\nP.S. Please use the side entrance.',
    'The delivery is confirmed.\n\nP.S. Please use the side entrance.',
  ],
  [
    'long_reply_bare_signoff',
    'Hi team,\n\nThe review is complete.\n\nWe have updated the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.\n\nBest,\nKevin',
    'Hi team,\n\nThe review is complete.\n\nWe have updated the plan.\n\nPlease send your comments tomorrow.\n\nWe will discuss them on Friday.\n\nBest,\nKevin',
  ],
  [
    'zoom_invite',
    'Topic: Weekly sync\nTime: September 12, 2026 10:00 AM\nJoin Zoom Meeting\nhttps://zoom.us/j/123456789\nMeeting ID: 123 456 789\nPasscode: 246810',
    'Topic: Weekly sync\nTime: September 12, 2026 10:00 AM\nJoin Zoom Meeting\nhttps://zoom.us/j/123456789\nMeeting ID: 123 456 789\nPasscode: 246810',
  ],
  [
    'shipping_block',
    'Your order is on its way.\n\nShip to:\nJordan Smith\n123 Main Street\nNew York, NY 10013',
    'Your order is on its way.\n\nShip to:\nJordan Smith\n123 Main Street\nNew York, NY 10013',
  ],
  [
    'calendar_block',
    'Design review\n\nWednesday, September 16, 2026\n10:00 AM - 11:00 AM\nLocation: Conference Room A',
    'Design review\n\nWednesday, September 16, 2026\n10:00 AM - 11:00 AM\nLocation: Conference Room A',
  ],
  [
    'two_link_share',
    'Here are the links you asked for:\nhttps://example.com/one\nhttps://example.com/two',
    'Here are the links you asked for:\nhttps://example.com/one\nhttps://example.com/two',
  ],
  [
    'contact_card_then_body',
    'Please reach out to our property manager directly:\nJohn Boga\nProperty Manager\njohn@example.com\n914-555-0123\n\nPlease copy me on your reply.',
    'Please reach out to our property manager directly:\nJohn Boga\nProperty Manager\njohn@example.com\n914-555-0123\n\nPlease copy me on your reply.',
  ],
  [
    'contact_list_followed_by_signoff',
    'If this matter is urgent, please contact:\n- Shane at shane@example.com or 424-555-0123\n- Victoria at victoria@example.com or 312-555-0123\n\nThank you,\nDominic',
    'If this matter is urgent, please contact:\n- Shane at shane@example.com or 424-555-0123\n- Victoria at victoria@example.com or 312-555-0123\n\nThank you,\nDominic',
  ],
  [
    'footer_phrase_followed_by_body',
    'The draft is ready.\n\nUnsubscribe from these notifications.\n\nWe should keep that sentence in the new template.',
    'The draft is ready.\n\nUnsubscribe from these notifications.\n\nWe should keep that sentence in the new template.',
  ],
  [
    'signoff_contacts',
    'The contract is ready.\n\nSincerely,\nMarcita Threash\nSenior Account Manager\nProtecting what matters most.\nmarcita@example.com\n404-555-0142',
    'The contract is ready.\n\nSincerely,\nMarcita Threash',
  ],
  ['mobile_footer', 'The review is complete.\n\nSent from my iPhone', 'The review is complete.'],
  [
    'legal_footer',
    'The review is complete.\n\nThis email and any attachments are confidential and intended solely\nfor the use of the individual to whom they are addressed.',
    'The review is complete.',
  ],
  [
    'wire_fraud_footer',
    'Escrow documents are ready for your signature.\n\nWIRE FRAUD IS REAL. Before wiring any money, call the intended\nrecipient at a number you know is valid to confirm the instructions.',
    'Escrow documents are ready for your signature.',
  ],
] as const

describe('plain signature preservation', () => {
  it.each(cases)('%s', (_name, input, expected) => {
    expect(removeSignature(input)).toBe(expected)
  })

  it.each(['\n', '\n\n'])('keeps a leading URL after %j', (separator) => {
    // Revert-check: text.ts leading URL guard / TextProcessing.unwrapEmailLineBreaks.
    expect(
      unwrapEmailLineBreaks('Emergency line: 914-555-0123' + separator + 'www.example.com'),
    ).toBe('Emergency line: 914-555-0123\n\nwww.example.com')
  })
})

it('keeps contact words inside personal names', () => {
  // Revert-check: shared name classifier in TextProcessing / web text.ts.
  expect(unwrapEmailLineBreaks('Best,\nMarcella Rossi')).toBe('Best,\nMarcella Rossi')
  expect(unwrapEmailLineBreaks('Best,\nMobile Office')).toBe('Best,\n\nMobile Office')
})
