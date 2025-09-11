import SwiftUI

struct RecipientField: View {
    @Binding var recipients: [Recipient]
    @Binding var inputText: String
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void
    var onTextChange: (String) -> Void
    
    struct Recipient: Identifiable, Equatable {
        let id = UUID()
        let email: String
        let displayName: String?
        let isValid: Bool
        
        init(email: String, displayName: String? = nil) {
            self.email = EmailNormalizer.normalize(email)
            self.displayName = displayName
            self.isValid = EmailValidator.isValid(email)
        }
        
        var display: String {
            if let displayName = displayName, !displayName.isEmpty {
                return displayName
            }
            return email
        }
    }
    
    var body: some View {
        WrappingHStack(alignment: .leading, spacing: 6) {
            ForEach(recipients) { recipient in
                RecipientChip(
                    recipient: recipient,
                    onRemove: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            recipients.removeAll { $0.id == recipient.id }
                        }
                    }
                )
            }
            
            TextField("To:", text: $inputText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .frame(minWidth: 100)
                .onSubmit {
                    addRecipientFromInput()
                    onSubmit()
                }
                .onChange(of: inputText) { _, newValue in
                    if newValue.hasSuffix(",") || newValue.hasSuffix(" ") {
                        let trimmed = String(newValue.dropLast())
                        if !trimmed.isEmpty {
                            inputText = trimmed
                            addRecipientFromInput()
                        } else {
                            inputText = ""
                        }
                    } else {
                        onTextChange(newValue)
                    }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private func addRecipientFromInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        if EmailValidator.isValid(trimmed) {
            let normalized = EmailNormalizer.normalize(trimmed)
            if !recipients.contains(where: { $0.email == normalized }) {
                withAnimation(.easeIn(duration: 0.2)) {
                    recipients.append(Recipient(email: trimmed))
                }
                inputText = ""
            }
        }
    }
}

struct RecipientChip: View {
    let recipient: RecipientField.Recipient
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text(recipient.display)
                .font(.subheadline)
                .foregroundColor(recipient.isValid ? .primary : .red)
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 15)
                .fill(recipient.isValid ? Color.gray.opacity(0.15) : Color.red.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(recipient.isValid ? Color.clear : Color.red.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

struct WrappingHStack: Layout {
    var alignment: Alignment = .center
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.positions[index].x,
                    y: bounds.minY + result.positions[index].y
                ),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            guard maxWidth > 0 && maxWidth.isFinite else {
                self.size = .zero
                return
            }
            
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            var maxX: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                // Validate size is finite
                guard size.width.isFinite && size.height.isFinite && 
                      size.width >= 0 && size.height >= 0 else {
                    continue
                }
                
                sizes.append(size)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
                maxX = max(maxX, x - spacing)
            }
            
            let finalWidth = max(0, maxX)
            let finalHeight = max(0, y + lineHeight)
            
            self.size = CGSize(
                width: finalWidth.isFinite ? finalWidth : 0,
                height: finalHeight.isFinite ? finalHeight : 0
            )
        }
    }
}

struct EmailValidator {
    static func isValid(_ email: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: email.utf16.count)
        return regex?.firstMatch(in: email, range: range) != nil
    }
}