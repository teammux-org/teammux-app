import AuthenticationServices
import Security

// MARK: - GitHubOAuthFlow

/// Handles browser-based GitHub OAuth authentication and Keychain token storage.
///
/// Uses `ASWebAuthenticationSession` to launch the GitHub authorize page,
/// then exchanges the returned code for a token (placeholder) and persists
/// it in the macOS Keychain under `com.teammux.app / github-token`.
@MainActor
class GitHubOAuthFlow: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {

    // MARK: - Published properties

    @Published var isAuthenticating: Bool = false
    @Published var token: String? = nil
    @Published var error: String? = nil

    // MARK: - Private state

    private let clientId = "TEAMMUX_GITHUB_CLIENT_ID"
    private let keychainService = "com.teammux.app"
    private let keychainAccount = "github-token"

    /// Holds a reference to the active session so ARC does not deallocate it
    /// while the browser window is open.
    private var authSession: ASWebAuthenticationSession?

    // MARK: - OAuth flow

    /// Kick off the GitHub OAuth flow in the user's default browser.
    ///
    /// On completion the authorization code is exchanged for a token
    /// (placeholder) and saved to the Keychain.
    func startOAuthFlow() {
        let scope = "repo"
        let callbackScheme = "teammux"

        guard let authURL = URL(
            string: "https://github.com/login/oauth/authorize"
                + "?client_id=\(clientId)"
                + "&scope=\(scope)"
                + "&redirect_uri=\(callbackScheme)://callback"
        ) else {
            error = "Failed to construct GitHub authorization URL"
            return
        }

        isAuthenticating = true
        error = nil

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, authError in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.isAuthenticating = false

                if let authError {
                    // User cancellation is not an error worth surfacing.
                    let nsError = authError as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    self.error = authError.localizedDescription
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.error = "No authorization code received from GitHub"
                    return
                }

                await self.exchangeCodeForToken(code)
            }
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session

        if !session.start() {
            isAuthenticating = false
            error = "Failed to start authentication session"
            authSession = nil
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? ASPresentationAnchor()
    }

    // MARK: - Keychain: load

    /// Attempt to load a previously-stored GitHub token from the Keychain.
    ///
    /// Returns `nil` if no token is found or the read fails.
    func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                error = "Keychain read failed (OSStatus \(status))"
            }
            return nil
        }

        guard let data = result as? Data,
              let tokenString = String(data: data, encoding: .utf8) else {
            return nil
        }

        token = tokenString
        return tokenString
    }

    // MARK: - Keychain: save (private)

    /// Persist the token in the macOS Keychain.
    ///
    /// If an entry already exists for the service/account pair it is deleted
    /// first so `SecItemAdd` does not return `errSecDuplicateItem`.
    private func saveToKeychain(_ tokenValue: String) {
        guard let tokenData = tokenValue.data(using: .utf8) else {
            error = "Failed to encode token for Keychain storage"
            return
        }

        // Remove any existing item to avoid duplicate-item errors.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            error = "Keychain delete failed (OSStatus \(deleteStatus))"
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            error = "Keychain save failed with status \(status)"
        }
    }

    // MARK: - Token exchange (private, placeholder)

    /// Exchange an authorization code for an access token.
    ///
    /// In production this would POST to GitHub's token endpoint with the
    /// client secret. For now we treat the authorization code itself as
    /// the token and persist it.
    private func exchangeCodeForToken(_ code: String) async {
        #warning("TODO: Implement proper OAuth token exchange — currently saves raw auth code as token")
        // Placeholder: a real implementation would call
        // https://github.com/login/oauth/access_token with the client
        // secret and exchange the code for an actual bearer token.
        saveToKeychain(code)
        token = code
    }
}
