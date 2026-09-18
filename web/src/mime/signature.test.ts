import { describe, expect, it } from 'vitest'
import { processChatBubbleText } from './bubble'
import { removeSignature } from './signature'
import { formatSignOffLineBreaks, unwrapEmailLineBreaks } from './text'

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

describe('authored content at inferred signature boundaries', () => {
  const preservedCases = [
    ...[
      'Emergency Contacts',
      'Support Team',
      'Emergency Numbers',
      'Emergency Contact Numbers',
      'Support Numbers',
      'Escalation Matrix',
      'On-Call Roster',
      'Building Support',
    ].map(
      (heading) =>
        [
          `${heading} contact list`,
          `Please keep these numbers handy.\n\n${heading}\nEmergency line: 212-555-1234\nCustomer service line: 212-555-5678`,
          `Please keep these numbers handy.\n\n${heading}\n\nEmergency line: 212-555-1234\n\nCustomer service line: 212-555-5678`,
        ] as const,
    ),
    [
      'privileged attachments instruction',
      'Hi John,\n\nThis email may contain privileged attachments. Please forward them to counsel.',
      'Hi John,\n\nThis email may contain privileged attachments. Please forward them to counsel.',
    ],
    [
      'confidential information instruction',
      'Hi John,\n\nThis email may contain confidential information. Please forward it to counsel.',
      'Hi John,\n\nThis email may contain confidential information. Please forward it to counsel.',
    ],
    [
      'legal-sounding correction',
      'Hello,\n\nThis email may contain mistakes. Please check the amounts before signing.',
      'Hello,\n\nThis email may contain mistakes. Please check the amounts before signing.',
    ],
    [
      'Form CRS revision request',
      'The draft is attached.\n\nOur Form CRS needs revision before Friday.',
      'The draft is attached.\n\nOur Form CRS needs revision before Friday.',
    ],
    [
      'preferences instruction',
      'Your account is ready.\n\nUpdate your preferences before the deadline.',
      'Your account is ready.\n\nUpdate your preferences before the deadline.',
    ],
    [
      'budget update below a name',
      'Please review the plan.\n\nJane Doe\nBudget has doubled.\njane@example.com\nhttps://example.com/project',
      'Please review the plan.\n\nJane Doe\n\nBudget has doubled.\n\njane@example.com\n\nhttps://example.com/project',
    ],
    [
      'budget update below a title',
      'Please review the plan.\n\nProject Manager\nBudget has doubled.\njane@example.com\nhttps://example.com/project',
      'Please review the plan.\n\nProject Manager\n\nBudget has doubled.\n\njane@example.com\n\nhttps://example.com/project',
    ],
    [
      'shared documents under a heading',
      'Please review these before our meeting.\n\nProject Documents\nhttps://example.com/revenue\nhttps://example.com/costs',
      'Please review these before our meeting.\n\nProject Documents\n\nhttps://example.com/revenue\n\nhttps://example.com/costs',
    ],
    [
      'shared links below a sales heading',
      'Here are the links:\nSales report\nhttps://example.com/revenue\nhttps://example.com/costs',
      'Here are the links:\n\nSales report\n\nhttps://example.com/revenue\n\nhttps://example.com/costs',
    ],
  ] as const

  it.each(preservedCases)('preserves %s in raw plain text', (_name, input) => {
    expect(removeSignature(input)).toBe(input)
  })

  it.each(preservedCases)('preserves %s through bubble processing', (_name, input, expected) => {
    expect(processChatBubbleText(input, { inputKind: 'plainText' }).mainText).toBe(expected)
  })

  it('still removes a specific confidentiality footer', () => {
    const input =
      'The review is complete.\n\nThis email may contain confidential or privileged information. If you are not the intended recipient, please delete it.'
    expect(removeSignature(input)).toBe('The review is complete.')
    expect(processChatBubbleText(input, { inputKind: 'plainText' }).mainText).toBe(
      'The review is complete.',
    )
  })

  it('still removes website links after an explicit personal sign-off', () => {
    const input =
      'The review is complete.\n\nBest,\nJane Doe\nhttps://janedoe.example.com\nhttps://linkedin.com/in/janedoe'
    expect(removeSignature(input)).toBe('The review is complete.\n\nBest,\nJane Doe')
    expect(processChatBubbleText(input, { inputKind: 'plainText' }).mainText).toBe(
      'The review is complete.\n\nBest,\n\nJane Doe',
    )
  })
})

describe('Front core parity', () => {
  // Revert-check: BARE_HOST_LINE_PATTERN in signature.ts evaluateLine.
  it('closes a signature at a bare host row and keeps the sign-off/name pair', () => {
    const text =
      'Sounds good.\n\nThanks,\nJane Doe\nAccount Manager\njane@acmeadvisory.com\nacmeadvisory.com'
    expect(removeSignature(text)).toBe('Sounds good.\n\nThanks,\nJane Doe')
  })

  // Revert-check: the hasContactInfo guard in signature.ts preservingSignOff.
  // The host is not a name, but an unpaired closing stays.
  it('does not preserve a bare host after the sign-off as a name', () => {
    const text = 'See you then.\n\nThanks,\nacmeadvisory.com\njane@acmeadvisory.com\n415-555-1212'
    expect(removeSignature(text)).toBe('See you then.\n\nThanks,')
  })

  // Revert-check: isAuthoredLeadInLine veto in removeSignature (Pass 2).
  it('preserves a payee address block introduced by a colon lead-in', () => {
    const text =
      'Please send the check to:\n\nJane Doe\n123 Main Street\nSpringfield, IL 62701\njane@example.test'
    expect(removeSignature(text)).toBe(text)
    const signed =
      'Please find my details below:\n\nThanks,\nJane Doe\n123 Main Street\nSpringfield, IL 62701\njane@example.test'
    expect(removeSignature(signed)).toBe('Please find my details below:\n\nThanks,\nJane Doe')
  })

  // HONEST SCOPE: passes at HEAD (filenames were never hosts); pins the TLD allowlist's rejections.
  it('does not treat filename lines as bare hosts', () => {
    const text = 'Attached are the files.\n\nBest,\nJane\n\nphotos.heic\nvideo.mov\nmain.cc'
    expect(removeSignature(text)).toBe(text)
  })

  // Revert-check: the contactSignals > bareHostSignals gate in removeSignature (Pass 2).
  // Extensions that double as country codes ("Logo.ai", "main.tf") and an authored list of
  // domains match BARE_HOST_LINE_PATTERN; they corroborate a real contact row but never anchor a
  // signature by themselves.
  it('never anchors a signature on bare host rows', () => {
    const files = 'Attached are the two files.\n\nBest,\nJane\n\nBrand.ai\nLogo.ai\nmain.tf'
    expect(removeSignature(files)).toBe(files)
    const domains =
      'Here are the domains to register.\n\nThanks,\nKevin\n\nKevinsbakery.com\nKevinsbakery.co\nKevinsbakery.shop'
    expect(removeSignature(domains)).toBe(domains)
  })

  // Revert-check: SIGN_OFF_PHRASES 'thanks again'; isSignOffLine punctuation trim.
  it('anchors a signature on gratitude closings and keeps the pair', () => {
    expect(
      removeSignature(
        'That works for me.\n\nThanks again,\nJane Doe\nCEO\njane@example.test\n415-555-1212',
      ),
    ).toBe('That works for me.\n\nThanks again,\nJane Doe')
    expect(
      removeSignature('Sounds good.\n\nThanks!\nJane Doe\nCEO\njane@example.test\n415-555-1212'),
    ).toBe('Sounds good.\n\nThanks!\nJane Doe')
  })

  // Revert-check: preservingSignOff returns index + 1 when the line after the closing
  // is not a name, so the closing stays and only the signature rows below it go.
  it('keeps an unpaired gratitude closing and drops a pipe-title signature', () => {
    expect(
      removeSignature(
        'Hi Bob,\n\nThank you so much!\nJane Doe | Director of Sales\nAcme Inc.\n555-123-4567\njane@acme.com',
      ),
    ).toBe('Hi Bob,\n\nThank you so much!')
    expect(
      removeSignature(
        'Thank you so much!\nJane Doe | Director of Sales\nAcme Inc.\n555-123-4567\njane@acme.com',
      ),
    ).toBe('Thank you so much!')
    expect(
      removeSignature(
        'Received, I will process the payment today.\n\nThank you very much.\nAcme Plumbing LLC\n555-123-4567\ninfo@acmeplumbing.com',
      ),
    ).toBe('Received, I will process the payment today.\n\nThank you very much.')
  })

  // Revert-check: the colon lead-in clamp in removeSignature (Pass 2). A referral
  // card under a colon intro stays when the sender's own signature follows.
  it('keeps a referral card when the sender signature follows a colon lead-in', () => {
    const text = [
      'Here is the contact info for the plumber:',
      '',
      'Mike Jones',
      '555-123-4567',
      'mike@jonesplumbing.com',
      '',
      'Thanks,',
      'John Smith',
      '555-987-6543',
      'john@acme.com',
    ].join('\n')
    expect(removeSignature(text)).toBe(
      'Here is the contact info for the plumber:\n\nMike Jones\n555-123-4567\nmike@jonesplumbing.com\n\nThanks,\nJohn Smith',
    )
  })

  // Revert-check: text.ts SIGN_OFF_WORDS derives from SIGN_OFF_PHRASES (longest first,
  // regex-escaped), so a multi-word gratitude closing breaks off inline while
  // sentence-shaped well-wishes stay out of the vocabulary and unbroken.
  it('breaks a multi-word gratitude closing off inline', () => {
    expect(formatSignOffLineBreaks('I will pay the balance today. Thanks so much, Jane')).toBe(
      'I will pay the balance today.\n\nThanks so much,\n\nJane',
    )
    expect(formatSignOffLineBreaks('See you Monday. Have a great day!')).toBe(
      'See you Monday. Have a great day!',
    )
  })
})
