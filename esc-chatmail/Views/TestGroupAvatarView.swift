import SwiftUI

struct TestGroupAvatarView: View {
    var body: some View {
        NavigationView {
            List {
                Section("Single Conversation") {
                    HStack {
                        SingleAvatarView(avatarPhoto: nil, participant: "John Doe")
                            .frame(width: 60, height: 60)
                        VStack(alignment: .leading) {
                            Text("John Doe")
                                .font(.headline)
                            Text("Hey, how are you?")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("Two Person Group") {
                    HStack {
                        GroupAvatarView(
                            avatarPhotos: [],
                            participants: ["Alice Smith", "Bob Johnson"]
                        )
                        .frame(width: 60, height: 60)
                        VStack(alignment: .leading) {
                            Text("Alice Smith, Bob Johnson")
                                .font(.headline)
                            Text("Let's meet tomorrow")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("Three Person Group") {
                    HStack {
                        GroupAvatarView(
                            avatarPhotos: [],
                            participants: ["Charlie Brown", "Diana Prince", "Edward Norton"]
                        )
                        .frame(width: 60, height: 60)
                        VStack(alignment: .leading) {
                            Text("Charlie, Diana, Edward")
                                .font(.headline)
                            Text("Project update ready")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section("Four Person Group") {
                    HStack {
                        GroupAvatarView(
                            avatarPhotos: [],
                            participants: ["Frank Miller", "Grace Kelly", "Henry Ford", "Isabel Martinez"]
                        )
                        .frame(width: 60, height: 60)
                        VStack(alignment: .leading) {
                            Text("Frank, Grace +2")
                                .font(.headline)
                            Text("Team meeting at 3pm")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Group Avatar Test")
        }
    }
}

struct TestGroupAvatarView_Previews: PreviewProvider {
    static var previews: some View {
        TestGroupAvatarView()
    }
}
