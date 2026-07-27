// Structural UI constants carried over from the iOS app (see plan §Design tokens).

export const CONVERSATION_ROW_HEIGHT = 88

export const AVATAR_SIZE_STANDARD = 44
export const AVATAR_SIZE_BUBBLE = 24
export const AVATAR_SIZE_COMPACT = 20

export const UNREAD_DOT_SIZE_LIST = 10
export const UNREAD_DOT_SIZE_BUBBLE = 6

export const BUBBLE_MAX_WIDTH = 320

/** Natural layout width email HTML is rendered at before scaling into cards. */
export const EMAIL_NATURAL_WIDTH = 600

/** Preview card height, clamped per iOS HTMLPreviewSizing (120…320, default 180). */
export const PREVIEW_HEIGHT_DEFAULT = 180
export const PREVIEW_HEIGHT_MIN = 120
export const PREVIEW_HEIGHT_MAX = 320

/** Outbound attachment limits (port of ImageProcessor / AttachmentPicker). */
export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024
export const MAX_IMAGE_DIMENSION = 4096
export const JPEG_QUALITY = 0.85
