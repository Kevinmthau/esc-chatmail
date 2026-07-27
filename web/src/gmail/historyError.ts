// Mirrors APIError.historyIdExpired (esc-chatmail/Services/API/APIError.swift):
// Gmail returns 404 from users.history.list when the startHistoryId is expired
// or invalid; sync must fall back to a recovery list-sync, never retry.

/** The stored historyId is too old or invalid; incremental sync must resync. */
export class HistoryIdExpiredError extends Error {
  constructor(message = 'Gmail history id expired or invalid') {
    super(message)
    this.name = 'HistoryIdExpiredError'
  }
}
