import SwiftUI

struct AutocompleteList: View {
    let contacts: [ContactsService.ContactMatch]
    let onSelect: (String, String?) -> Void
    let onDismiss: () -> Void
    @State private var selectedIndex: Int = 0
    @State private var expandedContactId: UUID?
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(contacts.enumerated()), id: \.element.id) { index, contact in
                if contact.emails.count > 1 && expandedContactId == contact.id {
                    MultiEmailContactRow(
                        contact: contact,
                        onSelectEmail: { email in
                            onSelect(email, contact.displayName)
                        }
                    )
                } else {
                    ContactRow(
                        contact: contact,
                        isSelected: index == selectedIndex,
                        onTap: {
                            if contact.emails.count > 1 {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedContactId = expandedContactId == contact.id ? nil : contact.id
                                }
                            } else {
                                onSelect(contact.primaryEmail, contact.displayName)
                            }
                        }
                    )
                }
                
                if index < contacts.count - 1 {
                    Divider()
                        .background(Color.gray.opacity(0.2))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemBackground))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 0.5)
        )
        .frame(maxHeight: 240)
        .onAppear {
            selectedIndex = 0
        }
    }
}

struct ContactRow: View {
    let contact: ContactsService.ContactMatch
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let imageData = contact.imageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(contact.displayName.prefix(1).uppercased())
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.gray)
                        )
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    
                    if contact.emails.count == 1 {
                        Text(contact.primaryEmail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(contact.emails.count) email addresses")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if contact.emails.count > 1 {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

struct MultiEmailContactRow: View {
    let contact: ContactsService.ContactMatch
    let onSelectEmail: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let imageData = contact.imageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Text(contact.displayName.prefix(1).uppercased())
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.gray)
                        )
                }
                
                Text(contact.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            VStack(spacing: 0) {
                ForEach(contact.emails, id: \.self) { email in
                    Button(action: {
                        onSelectEmail(email)
                    }) {
                        HStack {
                            Text(email)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 56)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.05))
                    }
                    .buttonStyle(.plain)
                    
                    if email != contact.emails.last {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
        }
    }
}