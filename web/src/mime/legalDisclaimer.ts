// Recognizes a legal disclaimer at the end of a message, for both the HTML cleanup
// (html.ts truncateTrailingLegalDisclaimer) and the plain-text one (signature.ts
// removeSignature). Mirrors iOS LegalDisclaimerPolicy, which carries the full rationale:
// the sentence markers only know a few fixed wordings, so a disclaimer worded any other
// way ("If you are not an addressee") stayed in the bubble. This counts distinct kinds of
// legal clause and asks for several, one of which must say who the message is for; a
// paragraph that names fewer than two ends the disclaimer, so an authored line after it
// keeps the whole tail.
//
// HONEST SCOPE: a hard-wrapped disclaimer whose line starts with a capital mid-sentence
// splits into two paragraphs, and the part with no clause stays; a disclaimer whose last
// paragraph names no clause stays whole.

export type LegalDisclaimerClause =
  | 'misdirectedReader'
  | 'confidentiality'
  | 'intendedReader'
  | 'notifySender'
  | 'deleteMessage'
  | 'prohibition'

export interface LegalDisclaimerParagraphEvidence {
  clauses: Set<LegalDisclaimerClause>
  isHeading: boolean
  isEnvironmentFooter: boolean
  isPostscript: boolean
}

// Explicit word edges, so JavaScript's `u` flag agrees with ICU on iOS (`\b` is
// ASCII-only here and Unicode-aware there).
const WORD_START = String.raw`(?<![\p{L}\p{N}_])`
const WORD_END = String.raw`(?![\p{L}\p{N}_])`

function pattern(source: string): RegExp {
  return new RegExp(source, 'iu')
}

const CLAUSE_PATTERNS: ReadonlyArray<[LegalDisclaimerClause, RegExp[]]> = [
  [
    'misdirectedReader',
    [
      pattern(
        WORD_START +
          String.raw`if you (?:are not|aren't|are no longer)(?: (?:the|an?))? (?:intended |named |designated |authori[sz]ed )?(?:recipient|addressee)`,
      ),
      pattern(WORD_START + String.raw`not (?:the|an?) intended recipient`),
      pattern(
        WORD_START +
          String.raw`received (?:this|the|that) (?:e-?mail|message|communication|transmission|electronic mail)(?: \S+){0,4}? (?:in error|by mistake|in mistake|erroneously)`,
      ),
    ],
  ],
  [
    'confidentiality',
    [pattern(WORD_START + String.raw`(?:confidential(?:ity)?|privileged|proprietary)` + WORD_END)],
  ],
  [
    'intendedReader',
    [
      pattern(
        WORD_START +
          String.raw`(?:intended|meant) (?:solely |only |exclusively )?for (?:only |solely |exclusively )?(?:the )?(?:(?:sole|exclusive|personal) )?(?:and confidential )?(?:use of )?(?:the )?(?:individual|person|entity|addressee|recipient|named|intended|designated)`,
      ),
      pattern(
        WORD_START + String.raw`for the (?:sole|exclusive)(?: and confidential)? use of` + WORD_END,
      ),
    ],
  ],
  [
    'notifySender',
    [
      pattern(
        WORD_START + String.raw`(?:notify|inform|advise|alert) (?:the sender|sender|us)` + WORD_END,
      ),
    ],
  ],
  [
    'deleteMessage',
    [
      pattern(
        WORD_START +
          String.raw`(?:delete|destroy|discard|erase|purge)` +
          WORD_END +
          String.raw`[^.;!?]{0,40}?` +
          WORD_START +
          String.raw`(?:e-?mails?|messages?|communications?|transmissions?|copies|attachments?)` +
          WORD_END,
      ),
    ],
  ],
  [
    'prohibition',
    [
      pattern(
        WORD_START +
          String.raw`(?:disclaim(?:s|ed|er)?|prohibited|unauthori[sz]ed|dissemination|reservation of rights)` +
          WORD_END,
      ),
    ],
  ],
]

// A paragraph that is only a disclaimer's title: "CONFIDENTIALITY NOTICE", "Disclaimer:".
const HEADING_PATTERN =
  /^(?:(?:important|legal|confidentiality|privacy|e-?mail)\s+)?(?:notice|disclaimer|confidential(?:ity)?(?:\s+notice)?)\s*:?$/iu

// "Please consider the environment before printing this e-mail."
const ENVIRONMENT_FOOTER_PATTERN = pattern(
  String.raw`^(?:please )?(?:consider the environment|think before you print)` + WORD_END,
)

// "P.S. …", "PS: …": a postscript is authored, whatever it says.
const POSTSCRIPT_PATTERN = /^p\.?\s?s(?:\.|:|\s|$)/iu

function normalized(text: string): string {
  return text
    .replace(/\u00a0/g, ' ')
    .replace(/\u2019/g, "'")
    .replace(/\s+/gu, ' ')
    .trim()
}

export function legalDisclaimerClauses(text: string): Set<LegalDisclaimerClause> {
  const value = normalized(text)
  const found = new Set<LegalDisclaimerClause>()
  for (const [clause, patterns] of CLAUSE_PATTERNS) {
    if (patterns.some((candidate) => candidate.test(value))) found.add(clause)
  }
  return found
}

export function legalDisclaimerParagraphEvidence(
  paragraph: string,
): LegalDisclaimerParagraphEvidence {
  const text = normalized(paragraph)
  return {
    clauses: legalDisclaimerClauses(text),
    isHeading: HEADING_PATTERN.test(text),
    isEnvironmentFooter: ENVIRONMENT_FOOTER_PATTERN.test(text),
    isPostscript: POSTSCRIPT_PATTERN.test(text),
  }
}

// A heading, an environment footer, or a paragraph naming two kinds of clause. One
// clause is the most an authored line next to a disclaimer usually names.
function belongsToDisclaimer(evidence: LegalDisclaimerParagraphEvidence): boolean {
  return (
    !evidence.isPostscript &&
    (evidence.isHeading || evidence.isEnvironmentFooter || evidence.clauses.size >= 2)
  )
}

// At least three kinds of clause, one of them saying who the message is for or what a
// reader it was not meant for must do.
export function isLegalDisclaimer(text: string): boolean {
  const found = legalDisclaimerClauses(text)
  if (!found.has('misdirectedReader') && !found.has('intendedReader')) return false
  return found.size >= 3
}

interface Paragraph {
  firstLine: number
  text: string
}

function startsLowercase(line: string): boolean {
  const first = [...line][0]
  return first !== undefined && first === first.toLowerCase() && first !== first.toUpperCase()
}

function continuesParagraph(previous: string, line: string): boolean {
  const last = [...previous].at(-1)
  if (last === undefined || '.!?:;'.includes(last)) return false
  return startsLowercase(line)
}

function paragraphs(lines: readonly string[]): Paragraph[] {
  const result: Paragraph[] = []
  let previousLine: string | null = null
  lines.forEach((rawLine, index) => {
    const line = normalized(rawLine)
    if (line.length === 0) {
      previousLine = null
      return
    }
    const current = result.at(-1)
    if (previousLine !== null && current && continuesParagraph(previousLine, line)) {
      current.text += ' ' + line
    } else {
      result.push({ firstLine: index, text: line })
    }
    previousLine = line
  })
  return result
}

/**
 * The index of the first line of a trailing disclaimer in `lines`, or null when the tail
 * is not one or nothing would be left above it. An empty line ends a paragraph; a line
 * starting with a lowercase letter after one that does not end a sentence continues it.
 * The disclaimer is the longest run of paragraphs at the end that each belong to one,
 * taken only when their text together is a disclaimer.
 */
export function trailingLegalDisclaimerStartLine(lines: readonly string[]): number | null {
  const found = paragraphs(lines)
  if (found.length < 2) return null

  let runStart = found.length
  while (
    runStart > 1 &&
    belongsToDisclaimer(legalDisclaimerParagraphEvidence(found[runStart - 1]!.text))
  ) {
    runStart -= 1
  }
  if (runStart >= found.length) return null

  const runText = found
    .slice(runStart)
    .map((paragraph) => paragraph.text)
    .join(' ')
  if (!isLegalDisclaimer(runText)) return null
  return found[runStart]!.firstLine
}
