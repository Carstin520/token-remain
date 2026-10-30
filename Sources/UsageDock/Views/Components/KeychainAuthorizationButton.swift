import SwiftUI

/// One-tap read-only authorization beside a notice that stopped at a Keychain
/// read needing the user's approval (Cursor's sealed login). It may show the
/// macOS prompt once; background refresh never does.
struct KeychainAuthorizationButton: View {
    @ObservedObject var store: UsageStore
    let provider: ProviderQuota.Provider
    @StateObject private var action = AsyncViewAction()

    var body: some View {
        Button(
            action.isRunning
                ? L10n.text("datasource.authorizing")
                : L10n.text("datasource.authorize_read")
        ) {
            action.start {
                _ = await store.authorizeProviderCredentials(provider)
            }
        }
        .controlSize(.small)
        .disabled(action.isRunning)
        .help(L10n.text("datasource.authorization_note"))
    }
}
