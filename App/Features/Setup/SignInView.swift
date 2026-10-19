import SwiftUI

/// The server's address, a name and a password.
struct SignInView: View {
    @Environment(AppState.self) private var state
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isSigningIn = false
    @FocusState private var focus: Field?

    private enum Field { case address, username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text("jellymc")
                            .font(.largeTitle.bold())
                        Text("Sign in to your Jellyfin server")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Server", text: $address, prompt: Text("192.168.1.10 or jellyfin.example.com"))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focus = .username }
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: signIn) {
                        HStack {
                            Spacer()
                            if isSigningIn { ProgressView().padding(.trailing, 6) }
                            Text("Sign In").bold()
                            Spacer()
                        }
                    }
                    .disabled(isSigningIn || address.isEmpty || username.isEmpty)
                }
            }
            .onAppear { focus = .address }
        }
    }

    private func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        error = nil
        Task {
            do {
                try await state.signIn(address: address, username: username, password: password)
            } catch {
                self.error = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}
