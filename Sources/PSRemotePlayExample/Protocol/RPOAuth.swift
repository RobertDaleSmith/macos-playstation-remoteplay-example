import CryptoKit
import Foundation

/// PSN account identity needed to link a console.
struct RPAccount: Codable, Equatable {
    let onlineId: String
    /// Numeric PSN user id.
    let userId: String
    /// Base64 of the user id as a little-endian 64-bit integer — the `Np-AccountId` sent when linking.
    let accountId: String
    /// SHA-256 hex of the user id; some discovery messages accept it as a credential.
    let credential: String

    static func make(onlineId: String, userId: String) -> RPAccount? {
        guard let value = UInt64(userId) else { return nil }
        var bytes: [UInt8] = []
        for i in 0..<8 { bytes.append(UInt8((value >> (8 * UInt64(i))) & 0xFF)) }
        let digest = SHA256.hash(data: Array(userId.utf8)).map { String(format: "%02x", $0) }
            .joined()
        return RPAccount(
            onlineId: onlineId, userId: userId, accountId: Data(bytes).base64EncodedString(),
            credential: digest)
    }
}

/// Sony OAuth flow used by the official Remote Play app. The user signs in inside a web view; we
/// capture the authorization code from the redirect and exchange it for account details.
enum RPOAuth {
    private static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectURL = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let tokenURL = URL(
        string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!

    /// Scopes Sony's Remote Play client is registered for. Asking for only `psn:clientapp` returns
    /// a "Something went wrong." page after the user submits credentials — the authorize step needs
    /// the full set that the maintained desktop clients request.
    static let scopes = [
        "psn:clientapp",
        "referenceDataService:countryConfig.read",
        "pushNotification:webSocket.desktop.connect",
        "sessionManager:remotePlaySession.system.update",
    ]

    /// Space-separated and percent-encoded for use in a query string or form body.
    static var encodedScope: String {
        scopes.joined(separator: " ").replacingOccurrences(of: " ", with: "%20")
    }

    static let loginURL: URL = {
        let query =
            "service_entity=urn:service-entity:psn"
            + "&response_type=code&client_id=\(clientId)"
            + "&redirect_uri=\(redirectURL)"
            + "&scope=\(encodedScope)"
            + "&request_locale=en_US&ui=pr"
            + "&service_logo=ps"
            + "&layout_type=popup"
            + "&smcid=remoteplay"
            + "&prompt=always"
            + "&PlatformPrivacyWs1=minimal&"
        return URL(
            string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?\(query)")!
    }()

    /// Extract the authorization code if `url` is the post-login redirect.
    static func authorizationCode(from url: URL) -> String? {
        guard url.absoluteString.hasPrefix(redirectURL),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            code.count > 1
        else { return nil }
        return code
    }

    private static var basicAuth: String {
        "Basic " + Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
    }

    static func fetchAccount(code: String, session: URLSession = .shared) async throws -> RPAccount
    {
        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        // Sony wants the same scope set here as in the authorize step.
        tokenRequest.httpBody = Data(
            ("grant_type=authorization_code&code=\(code)"
                + "&scope=\(encodedScope)"
                + "&redirect_uri=\(redirectURL)&").utf8)
        tokenRequest.timeoutInterval = 10
        let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        guard (tokenResponse as? HTTPURLResponse)?.statusCode == 200,
            let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any],
            let token = tokenJSON["access_token"] as? String
        else {
            throw RPError.oauthFailed("token exchange rejected")
        }

        var infoRequest = URLRequest(url: tokenURL.appendingPathComponent(token))
        infoRequest.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        infoRequest.timeoutInterval = 10
        let (infoData, infoResponse) = try await session.data(for: infoRequest)
        guard (infoResponse as? HTTPURLResponse)?.statusCode == 200,
            let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
            let userId = info["user_id"] as? String
        else {
            throw RPError.oauthFailed("could not read account info")
        }
        let onlineId = (info["online_id"] as? String) ?? userId
        guard let account = RPAccount.make(onlineId: onlineId, userId: userId) else {
            throw RPError.oauthFailed("unexpected account id format")
        }
        return account
    }
}
