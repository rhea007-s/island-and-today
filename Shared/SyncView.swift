import SwiftUI

/// Sign in once on each device with the same email; tasks then follow you
/// between the iPhone and the Mac. Used as a sheet on iPhone and as a section
/// of the Mac island's Settings.
struct SyncView: View {
    @ObservedObject private var sync = CloudSync.shared
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false

    var body: some View {
        if let account = sync.email {
            signedIn(account)
        } else {
            signInForm
        }
    }

    private func signedIn(_ account: String) -> some View {
        Group {
            LabeledContent("Account", value: account)
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    switch sync.status {
                    case .syncing:
                        ProgressView().controlSize(.small)
                        Text("Syncing…")
                    case .failed(let message):
                        Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                        Text(message).lineLimit(2)
                    default:
                        Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                        if let last = sync.lastSync {
                            Text("Synced \(last, format: .dateTime.hour().minute())")
                        } else {
                            Text("Ready")
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }
            HStack {
                Button("Sync now") { sync.sync() }
                    .disabled(sync.status == .syncing)
                Spacer()
                Button("Sign out", role: .destructive) { sync.signOut() }
            }
            .buttonStyle(.borderless)
        }
    }

    private var signInForm: some View {
        Group {
            TextField("Email", text: $email)
                .textContentType(.username)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField(creating ? "New password (6+ characters)" : "Password", text: $password)
                .textContentType(creating ? .newPassword : .password)
                .onSubmit(submit)
            if case .failed(let message) = sync.status {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                Button(creating ? "Create account" : "Sign in", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(email.isEmpty || password.count < 6 || sync.status == .syncing)
                if sync.status == .syncing { ProgressView().controlSize(.small) }
                Spacer()
                Button(creating ? "I have an account" : "New here? Create one") { creating.toggle() }
                    .buttonStyle(.borderless)
                    .font(.footnote)
            }
            Text("Use the same email on your iPhone and your Mac. Your tasks are stored in your own private space; nobody else can read them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func submit() {
        let address = email.trimmingCharacters(in: .whitespaces)
        let secret = password
        Task {
            await sync.signIn(email: address, password: secret, createAccount: creating)
            if sync.isSignedIn { password = "" }
        }
    }
}
