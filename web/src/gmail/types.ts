// Gmail REST API DTOs (subset the app consumes).
// Reference: esc-chatmail/Services/API/GmailAPIModels.swift

export interface GmailProfile {
  emailAddress: string
  messagesTotal?: number
  threadsTotal?: number
  historyId: string
}

export interface GmailHeader {
  name: string
  value: string
}

export interface GmailBody {
  attachmentId?: string
  size?: number
  /** base64url-encoded bytes; absent for large parts (see attachmentId). */
  data?: string
}

export interface GmailPart {
  partId?: string
  mimeType?: string
  filename?: string
  headers?: GmailHeader[]
  body?: GmailBody
  parts?: GmailPart[]
}

export interface GmailMessage {
  id: string
  threadId: string
  labelIds?: string[]
  snippet?: string
  historyId?: string
  /** Stringified epoch milliseconds. */
  internalDate?: string
  payload?: GmailPart
  sizeEstimate?: number
}

export interface GmailMessageRef {
  id: string
  threadId: string
}

export interface MessagesListResponse {
  messages?: GmailMessageRef[]
  nextPageToken?: string
  resultSizeEstimate?: number
}

export interface HistoryMessageWrapper {
  message: GmailMessageRef & { labelIds?: string[] }
}

export interface HistoryLabelChange {
  message: GmailMessageRef
  labelIds?: string[]
}

export interface HistoryRecord {
  id: string
  messages?: GmailMessageRef[]
  messagesAdded?: HistoryMessageWrapper[]
  messagesDeleted?: HistoryMessageWrapper[]
  labelsAdded?: HistoryLabelChange[]
  labelsRemoved?: HistoryLabelChange[]
}

export interface HistoryListResponse {
  history?: HistoryRecord[]
  nextPageToken?: string
  historyId?: string
}

export interface GmailLabel {
  id: string
  name: string
  type?: string
}

export interface LabelsListResponse {
  labels?: GmailLabel[]
}

export interface SendAsResponse {
  sendAs?: SendAsEntry[]
}

export interface SendAsEntry {
  sendAsEmail: string
  displayName?: string
  isDefault?: boolean
  isPrimary?: boolean
  verificationStatus?: string
}

export interface AttachmentResponse {
  size: number
  /** base64url-encoded bytes. */
  data: string
}

export interface SendMessageResponse {
  id: string
  threadId: string
  labelIds?: string[]
}
