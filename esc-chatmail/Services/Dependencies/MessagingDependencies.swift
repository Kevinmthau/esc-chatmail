struct MessagingDependencies {
    let makeMessageActions: @MainActor () -> MessageActions
    let makeOutboundMessageCoordinator: @MainActor () -> any OutboundMessageCoordinating
    let makeOutboundReplyContextBuilder: @MainActor () -> OutboundReplyContextBuilder
    let makeComposeReplyModeContextBuilder: @MainActor () -> ComposeReplyModeContextBuilder
    let makeComposeForwardModeContextBuilder: @MainActor () -> ComposeForwardModeContextBuilder
    let makeOutboundAttachmentContextBuilder: @MainActor () -> OutboundAttachmentContextBuilder
}
