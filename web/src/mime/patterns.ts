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
