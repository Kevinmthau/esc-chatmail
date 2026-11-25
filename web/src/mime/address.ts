// Header email/display-name extraction for MIME parsing.
//
// The extraction and normalization helpers are owned by the identity module
// (src/identity/normalizeEmail.ts, the EmailNormalizer.swift port) and
// re-exported here so both modules share one implementation. Note that
// normalizeEmail performs full canonicalization (trim + lowercase, plus
// Gmail dot-strip / plus-truncation / googlemail→gmail), matching iOS
// MessageProcessor.parseEmailAddresses which stores canonicalized addresses
// on parsed recipient rows.
// addressTokens (EmailAddressListParser.addressTokens) lives there too, beside
// the mailbox scanner that must read quotes and comments by its rules.
export {
  addressTokens,
  displayNameInToken,
  extractDisplayName,
  extractEmail,
  mailboxAddress,
  normalizeEmail,
} from '../identity/normalizeEmail'
