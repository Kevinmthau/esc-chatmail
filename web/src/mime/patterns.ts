// Shared, pre-compiled pattern definitions for the text-processing pipeline.
// Port of esc-chatmail/Services/TextProcessing/TextPatterns.swift.

/** Matches an email address anywhere in a line. */
export const EMAIL_ADDRESS_PATTERN = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i

/** Matches http(s) URLs and bare `www.` hosts anywhere in a line. */
export const WEB_URL_PATTERN = /\bhttps?:\/\/\S+|\bwww\.[^\s]+/i

/** Phone-number candidate: 7+ digits with common separators. */
export const PHONE_PATTERN = /\b\+?\d[\d\s().-]{6,}\b/

/** Street/suite/floor keywords, matched on word boundaries. */
export const ADDRESS_KEYWORD_PATTERN =
  /\b(?:street|st|avenue|ave|road|rd|boulevard|blvd|lane|ln|drive|dr|suite|ste|floor|fl)\b\.?/i

/** Standalone one-letter contact labels ("m:", "t.", "p"). */
export const STANDALONE_CONTACT_LABEL_PATTERN = /^(m|c|o|f|d|t|p)[:.]?$/i

/** Signature delimiter lines ("--", "___", em/en dash variants). */
export const SIGNATURE_DELIMITER_PATTERN = /^(--|--\s|---|___|—|–|-)$|^[-_]{2,}$/i

// Localized quoted-reply header prefixes (lowercased), grouped by header role.
export const FROM_HEADER_PREFIXES = ['from:', 'von:', 'de:', 'de :', 'da:', 'van:'] as const

export const TO_HEADER_PREFIXES = ['to:', 'an:', 'à:', 'à :', 'para:', 'aan:'] as const

export const SENT_OR_DATE_HEADER_PREFIXES = [
  'sent:',
  'date:',
  'gesendet:',
  'datum:',
  'envoyé:',
  'envoyé :',
  'enviado:',
  'inviato:',
  'verzonden:',
] as const

export const SUBJECT_HEADER_PREFIXES = [
  'subject:',
  'betreff:',
  'objet:',
  'objet :',
  'asunto:',
  'oggetto:',
  'assunto:',
  'onderwerp:',
] as const

/** Per-part MIME header prefixes (lowercased) stripped from displayed text. */
export const MIME_HEADER_PREFIXES = [
  'content-type:',
  'content-transfer-encoding:',
  'content-disposition:',
  'content-id:',
  'content-description:',
  'x-attachment-id:',
  'mime-version:',
] as const

/** Extracts boundary tokens from Content-Type headers. */
export const MIME_BOUNDARY_PATTERN = /boundary\s*=\s*(?:"([^"]+)"|([^\s;]+))/i

export function matchIndex(pattern: RegExp, text: string): number | null {
  const match = pattern.exec(text)
  return match ? match.index : null
}

export function testPattern(pattern: RegExp, text: string): boolean {
  return pattern.test(text)
}

export function isUppercaseChar(ch: string): boolean {
  return ch !== ch.toLowerCase()
}

export function isLetterChar(ch: string): boolean {
  return /\p{L}/u.test(ch)
}

export function isDigitChar(ch: string): boolean {
  return /\p{Nd}/u.test(ch)
}

/** Shared signature vocabulary; HTML consumers adapt tag/whitespace boundaries. */
export const SIGN_OFF_PHRASES = new Set([
  'all the best',
  'best',
  'best regards',
  'best wishes',
  'cheers',
  'kind regards',
  'many thanks',
  'regards',
  'sincerely',
  'take care',
  'thank you',
  'thanks',
  'warm regards',
  'warmly',
  'yours truly',
])

export const LEGAL_FOOTER_OPENERS = [
  String.raw`^\s*confidentiality notice\s*:`,
  String.raw`^\s*this e-?mail (?:and any attachments|is confidential|may contain)\b`,
  String.raw`^\s*disclaimer\s*:`,
]

// Explicit phone-label phrases avoid treating fields such as "Service period" as contact details.
// Callers also apply the normal phone-candidate/date and suffix validation.
const DESCRIPTIVE_PHONE_LABEL = String.raw`(?:after[ -]hours|(?:emergency|after[ -]hours|toll[ -]free|customer service|service|dispatch)[ -]+(?:phone|line|number)(?:[ -]+after[ -]hours)?)\s*:`
const DESCRIPTIVE_PHONE_NUMBER = String.raw`(?=(?:[\s().+-]*\d){7})\+?\(?\d{1,4}\)?(?:[\s.-]+\(?\d{1,4}\)?){1,4}`
const DESCRIPTIVE_PHONE_SUFFIX = String.raw`(?:\s*(?:x|ext\.?|extension|#)\s*:?\s*\d+|\s*\((?:mobile|cell|office|work|home|direct|desk|main|fax)\))?`
export const DESCRIPTIVE_PHONE_LINE_PATTERN = new RegExp(
  '^' +
    DESCRIPTIVE_PHONE_LABEL +
    String.raw`\s*` +
    DESCRIPTIVE_PHONE_NUMBER +
    DESCRIPTIVE_PHONE_SUFFIX +
    '$',
  'i',
)

export const SIGNATURE_NAME_CONTACT_WORD_PATTERN = /\b(?:fax|mobile|office|cell|phone)\b/i
const SIGNATURE_SUPPORT_KEYWORD_PATTERN =
  /\b(?:director|manager|vp|vice president|president|founder|ceo|cfo|cto|coo|realtor|broker|associate|sales|agent|partner|principal|owner|specialist)\b|\s(?:inc|llc|ltd|corp|corporation|company|partners|group|llp|lp)\b|\sco\./i
// Added roles require a complete title phrase, not a keyword anywhere in a sentence.
const SIGNATURE_ADDITIONAL_SUPPORT_TITLE_PATTERN =
  /^(?:(?:(?:chief|executive|senior|junior|lead|staff|loan|financial|investment|legal|technical|software|systems|project|account|marketing|operations|general|assistant)\s+){0,2}(?:officer|chief|advisor|consultant|engineer|attorney|counsel|analyst|coordinator)|[a-z][a-z'’.-]+\s+(?:insurance|travel|real estate|staffing|marketing|advertising|creative)\s+agency)$/i
const SIGNATURE_SUPPORT_PROSE_PATTERN =
  /\b(?:please|not|never|no|without|must|shall|should|will|would|could|cannot|is|are|was|were|be|been|being|pending|awaiting|required|approval|pay|payment|fees|due|my|our|your|their)\b|^(?:i|we|you|he|she|it|they|do|check|ask|ensure|remember|confirm|send|wait|get|need|call|contact|use)\b/i
const SIGNATURE_TITLE_JOINERS = new Set([
  'and',
  'of',
  'at',
  'for',
  'the',
  'in',
  'de',
  'van',
  'von',
  '&',
  '/',
  '|',
  '-',
  '–',
])

export function isStrongSignatureSupportLine(line: string): boolean {
  const trimmed = line.trim()
  const words = trimmed.split(/\s+/)
  if (words.length >= 8) return false
  // Capitalization does not make an instruction a title (e.g. "DO NOT PAY THE CONSULTANT").
  if (SIGNATURE_SUPPORT_PROSE_PATTERN.test(trimmed)) return false
  if (/[.?!]$/.test(trimmed) && !/\b(?:inc|co|corp)\.$/i.test(trimmed)) return false
  if (SIGNATURE_ADDITIONAL_SUPPORT_TITLE_PATTERN.test(trimmed)) return true
  if (!SIGNATURE_SUPPORT_KEYWORD_PATTERN.test(trimmed)) return false

  // A role mentioned in an instruction is not a removable title. Unknown
  // lowercase phrases stay visible; standalone roles still work in any case.
  if (words.length === 1) return true
  return words.every((word) => {
    if (SIGNATURE_TITLE_JOINERS.has(word.toLowerCase())) return true
    const firstLetter = word.match(/\p{L}/u)?.[0]
    return firstLetter !== undefined && isUppercaseChar(firstLetter)
  })
}

export function shouldPreserveSignatureNameLine(line: string): boolean {
  const trimmed = line.trim()
  return (
    trimmed.length > 0 &&
    trimmed.length <= 40 &&
    /\p{L}/u.test(trimmed) &&
    !/\p{Nd}/u.test(trimmed) &&
    !/@|http|www\.|\||tel:/i.test(trimmed) &&
    !SIGNATURE_NAME_CONTACT_WORD_PATTERN.test(trimmed) &&
    trimmed.split(/\s+/).length <= 4 &&
    !isStrongSignatureSupportLine(trimmed)
  )
}
