import AuthenticationServices
import CryptoKit
import OSLog
import WebKit

// Passkeys and security keys, for a browser that isn't Safari.
//
// Left to WebKit, a sign-in page that offers your passkey under its name
// field (conditional mediation) has WebKit open an AutoFill operation with
// macOS's AuthenticationServicesAgent, held for as long as the page waits.
// If yab dies meanwhile, quit, crash, killed, the agent never lets go of
// it, and refuses every passkey request yab makes after that, before any
// sheet: "Request already in progress for specified application identifier"
// (AuthenticationServicesCore.AuthorizationError 1). "Authentication failed"
// on every site, until the agent restarts with the Mac. Found 24 Sep 2026 on
// an agent that had held one for a day.
//
// So yab carries the ceremony itself, and never opens that operation: it takes the request from the page, checks
// it against the frame it came from, and hands it to AuthenticationServices
// through the API made for browsers, with client data it writes, the origin
// in it is the one WebKit reports for the frame, never one the page states.
// A page's navigator.credentials answers any request for a public key from
// here: the Mac's own sheet, with Touch ID and the passkeys in iCloud Keychain
// or a password app, an iPhone nearby over the QR code, or a security key.
// What comes back goes to the page as the credential WebKit would have made.
//
// On Chromium tabs with CEF 0127 the Mac's passkeys are offered under the
// name field, in Yab's own rows, as Chromium offers them
// (ChromiumWebAuthn+Conditional.swift). Not yet on WebKit tabs: pages are
// told the field has none to offer, so they show their own
// passkey button, unless a password manager extension that keeps passkeys
// is there to offer its own. A request made that way is the extension's to
// answer; what it leaves to yab just waits, as it does while nobody picks
// one, never reaching macOS.
@MainActor
final class Passkeys: NSObject {
    static let shared = Passkeys()

    private static let log = Logger(subsystem: Store.productionBundleID, category: "Passkeys")

    // MARK: - the Mac's permission

    /// Whether this Mac lets yab use its passkeys at all: a question
    /// macOS puts once to a browser other than Safari, the answer kept in
    /// System Settings › Privacy & Security.
    static var access: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState {
        ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials
    }

    /// Everyone waiting on that question while it is on screen.
    private static var waiting: [() -> Void]?

    /// Asked before the first ceremony, where it makes sense, a site has
    /// just asked for a passkey, and then never again.
    private static func ensure(_ then: @escaping () -> Void) {
        note("access \(access.rawValue) entitled=\(Preferences.entitledToPasskeys)")
        guard Preferences.entitledToPasskeys, access == .notDetermined else { return then() }
        if waiting != nil {
            waiting?.append(then)
            return
        }
        waiting = [then]
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { state in
            DispatchQueue.main.async {
                note("access asked: \(state.rawValue)")
                let everyone = waiting ?? []
                waiting = nil
                everyone.forEach { $0() }
            }
        }
    }

    // MARK: - a ceremony

    /// How many a page has asked for, and the last as it was checked, for
    /// the bench.
    private(set) static var asked = 0
    private(set) static var last: [String: Any] = [:]
    /// What the last ceremonies met, for the bench and the log: the windows
    /// as they were, the anchor macOS was given, and how it ended.
    private(set) static var trail: [String] = []
    /// A probe world that asks for the Mac's real sheet (YAB_PASSKEY_SHEET=1),
    /// on a farm Mac's test screen: the focus check and the sheet as shipped.
    static let realSheet = ProcessInfo.processInfo.environment["YAB_PASSKEY_SHEET"] == "1"
    static func note(_ line: String) {
        trail.append(line)
        if trail.count > 60 { trail.removeFirst(trail.count - 60) }
        log.notice("\(line, privacy: .public)")
    }
    static func describe(_ window: NSWindow?) -> String {
        guard let window else { return "none" }
        return "\(type(of: window))#\(window.windowNumber) key=\(window.isKeyWindow) main=\(window.isMainWindow) visible=\(window.isVisible) onscreen=\(window.occlusionState.contains(.visible)) level=\(window.level.rawValue) sheet=\(window.attachedSheet != nil) frame=\(NSStringFromRect(window.frame))"
    }
    static func windows() -> String {
        "active=\(NSApp.isActive) key=\(describe(NSApp.keyWindow)) all=[" + NSApp.windows.filter(\.isVisible).map(describe).joined(separator: "; ") + "]"
    }

    /// The one on screen, and whom to answer when it ends. A new request
    /// ends the one before, as a page asking twice gets in any browser.
    private var controller: ASAuthorizationController?
    private var token: String?
    private var answer: (([String: Any]) -> Void)?
    private weak var anchor: NSWindow?
    /// Requests waiting to start, behind the Mac's passkey question: which
    /// of them starts once it is answered (PasskeyWaits).
    private var waits = PasskeyWaits()

    /// Where a request came from, as WebKit knows it rather than as the
    /// page says.
    struct Caller {
        let origin: PageOrigin
        let mainFrame: Bool
        /// The host of the page the frame is in.
        let pageHost: String?
        let window: NSWindow?
        /// An extension's own page, its popup or a window of its own: the
        /// extension's chrome-extension:// origin, and which sites it may
        /// ask for: the sites it was given.
        var extensionPage: ExtensionPage? = nil
        /// A Chromium request, checked by Chromium itself (CEF patch 0113):
        /// the RP ID against the origin and related origins, the frame's
        /// publickey-credentials permission, an extension's host permissions.
        /// Its origin is the one Chromium verified; nothing here checks again.
        var chromium: ChromiumVerified? = nil
    }

    struct ChromiumVerified: Equatable {
        /// The calling frame's origin, as Chromium serializes it
        /// (https://example.com, chrome-extension://id).
        let origin: String
        /// The top-level page's, for clientDataJSON when the frame is
        /// another site's.
        let topOrigin: String
        let crossOrigin: Bool
    }

    struct ExtensionPage {
        let origin: String
        let mayClaim: (String) -> Bool
    }

    func cancel(token: String?) {
        guard let token else { return }
        if token == self.token { controller?.cancel() } else { waits.withdraw(token) }
    }

    func perform(_ body: [String: Any], from caller: Caller, answer: @escaping ([String: Any]) -> Void) {
        // Switched off in Settings: what reaches here came through an
        // extension's page script, which the patch runs ahead of whatever the
        // setting, the site hears no, as it would from a browser without them.
        guard FormRelay.passkeysOffered else {
            return refuse(answer, "NotAllowedError", "The operation either timed out or was not allowed.")
        }
        let kind = body["kind"] as? String ?? ""
        if let verified = caller.chromium {
            guard (Store.testing && !Passkeys.realSheet) || (NSApp.isActive && caller.window?.isKeyWindow == true) else {
                return refuse(answer, "NotAllowedError", "The document is not focused.")
            }
            let named = kind == "create" ? (body["rp"] as? [String: Any])?["id"] as? String : body["rpId"] as? String
            guard let rp = named?.lowercased(), !rp.isEmpty else {
                return refuse(answer, "SecurityError", "The request names no relying party.")
            }
            return proceed(body, kind: kind, rp: rp, origin: verified.origin, caller: caller, answer: answer)
        }
        let scheme = caller.origin.scheme.lowercased()
        let host = caller.origin.host.lowercased()
        let local = host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1"
        guard !host.isEmpty, caller.extensionPage != nil || scheme == "https" || (scheme == "http" && local) else {
            return refuse(answer, "NotAllowedError", "Passkeys need a secure page.")
        }
        // The page in front of you only: a tab behind, a window behind, or
        // yab itself behind doesn't get to bring up the Mac's sheet over
        // what you're looking at. A test run is always behind.
        guard (Store.testing && !Passkeys.realSheet) || (NSApp.isActive && caller.window?.isKeyWindow == true) else {
            return refuse(answer, "NotAllowedError", "The document is not focused.")
        }
        // A frame from another site can't ask on the page's behalf.
        // The same site, not only the same host: a sign-in frame from
        // login.example.com on example.com is the site asking. An
        // extension's page asks only from its own document.
        guard caller.mainFrame || (caller.extensionPage == nil && caller.pageHost.map({ Vault.registrable($0) == Vault.registrable(host) }) == true) else {
            return refuse(answer, "NotAllowedError", "Passkeys can't be asked for from another site's frame.")
        }
        let named = kind == "create" ? (body["rp"] as? [String: Any])?["id"] as? String : body["rpId"] as? String
        let rp = (named.flatMap { $0.isEmpty ? nil : $0 } ?? host).lowercased()
        let port = caller.origin.port
        let origin = caller.extensionPage?.origin ?? "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)" + (port == 0 ? "" : ":\(port)")
        // An extension's page names a site it was given, Bitwarden's popup
        // its vault's (vault.bitwarden.com) to unlock with a passkey, as
        // Chrome lets it; a page, its own site or a domain above it.
        if caller.extensionPage.map({ $0.mayClaim(rp) }) ?? Passkeys.fits(rp, host) {
            return proceed(body, kind: kind, rp: rp, origin: origin, caller: caller, answer: answer)
        }
        // Or a site that names this page's origin as its own in its
        // related origins file: X's passkeys are twitter.com's, asked for
        // from x.com.
        let refusal = "The relying party ID is not a registrable domain suffix of, nor equal to the current domain."
        guard caller.extensionPage == nil, scheme == "https", RelatedOrigins.valid(rp) else {
            return refuse(answer, "SecurityError", refusal)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await RelatedOrigins.allow(rp: rp, origin: origin) else {
                return self.refuse(answer, "SecurityError", refusal)
            }
            self.proceed(body, kind: kind, rp: rp, origin: origin, caller: caller, answer: answer)
        }
    }

    /// The request once its relying party is one the page may name.
    private func proceed(_ body: [String: Any], kind: String, rp: String, origin: String, caller: Caller,
                         answer: @escaping ([String: Any]) -> Void) {
        guard let challenge = Passkeys.data(body["challenge"]), !challenge.isEmpty else {
            return refuse(answer, "TypeError", "A challenge is required.")
        }
        var clientData = ASPublicKeyCredentialClientData(challenge: challenge, origin: origin)
        // Another site's frame: clientDataJSON says so, with the page it is
        // in, as Chromium writes it.
        if let verified = caller.chromium {
            clientData.crossOrigin = verified.crossOrigin ? .crossOrigin : .sameOriginWithAncestors
            if verified.crossOrigin { clientData.topOrigin = verified.topOrigin }
        }

        let requests: [ASAuthorizationRequest]
        switch kind {
        case "get":
            requests = assertion(body, rp: rp, clientData: clientData)
        case "create":
            guard let made = registration(body, rp: rp, clientData: clientData) else {
                return refuse(answer, "TypeError", "The request names no user, or one too long.")
            }
            requests = made
        default:
            return refuse(answer, "NotSupportedError", "Not a passkey request.")
        }
        guard !requests.isEmpty else {
            return refuse(answer, "NotSupportedError", "No authenticator here can make that kind of key.")
        }

        Passkeys.asked += 1
        Passkeys.last = ["kind": kind, "rp": rp, "origin": origin, "requests": requests.count, "prf": body["prf"] is [String: Any]]
        Passkeys.log.notice("\(kind, privacy: .public) for \(rp, privacy: .public) from \(origin, privacy: .public)")
        // A test run never shows the sheet: it would open on the screen of
        // whoever is working beside it. It gets a credential made up on the
        // spot instead, so the checks above and the page's side are still
        // what they are for real.
        if Store.testing && !Passkeys.realSheet {
            // A picked passkey signs as itself.
            let picked = body["platformOnly"] as? Bool == true ? Passkeys.descriptors(body["allowCredentials"]).first?.id : nil
            var reply = Passkeys.rehearsal(kind, rp: rp, origin: origin, challenge: challenge,
                                           crossOrigin: caller.chromium?.crossOrigin == true ? caller.chromium?.topOrigin : nil,
                                           id: picked)
            // PRF made up from the salt, so a page can tell its salt arrived.
            if let prf = body["prf"] as? [String: Any] {
                let salt = ((prf["eval"] as? [String: Any])?["first"] as? String).flatMap(Passkeys.data)
                let first = salt.map { SymmetricKey(data: SHA256.hash(data: Data("yab-rehearsal".utf8) + $0)) }
                reply["prf"] = Passkeys.prfReply(first: first, second: nil, enabled: kind == "create" ? true : nil)
            }
            return answer(reply)
        }

        let token = body["token"] as? String
        let ask = waits.asked()
        Passkeys.ensure { [weak self] in
            guard let self else { return }
            switch self.waits.turn(ask, token: token) {
            case .aborted: answer(Passkeys.failure("AbortError", "The operation was aborted."))
            case .superseded: answer(Passkeys.failure("NotAllowedError", "A newer request took its place."))
            case .start: self.begin(requests, token: token, in: caller.window, answer: answer)
            }
        }
    }

    private func begin(_ requests: [ASAuthorizationRequest], token: String?, in window: NSWindow?, answer: @escaping ([String: Any]) -> Void) {
        if let running = controller {
            let previous = self.answer
            clear()
            running.cancel()
            previous?(Passkeys.failure("NotAllowedError", "A newer request took its place."))
        }
        let controller = ASAuthorizationController(authorizationRequests: requests)
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        self.token = token
        self.answer = answer
        self.anchor = window
        Passkeys.note("perform \(requests.count) requests in \(Passkeys.describe(window)); \(Passkeys.windows())")
        controller.performRequests()
    }

    // MARK: - requests

    private func assertion(_ body: [String: Any], rp: String, clientData: ASPublicKeyCredentialClientData) -> [ASAuthorizationRequest] {
        let allowed = Passkeys.descriptors(body["allowCredentials"])
        let verification = Passkeys.verification(body["userVerification"])
        let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
            .createCredentialAssertionRequest(clientData: clientData)
        platform.allowedCredentials = allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id) }
        platform.userVerificationPreference = verification
        let prf = Passkeys.prfAssertion(body["prf"])
        platform.prf = prf
        // A passkey's blob, read or written, as Chromium does through iCloud
        // Keychain (device/fido/mac/icloud_keychain.mm). macOS keeps it for
        // its own passkeys only; a security key's answer says nothing of it.
        platform.largeBlob = Passkeys.largeBlobAssertion(body["largeBlob"])
        var requests: [ASAuthorizationRequest] = [platform]
        // A passkey picked under the box (ChromiumWebAuthn+Conditional) is
        // the Mac's: no security key is offered beside it, as Chromium sends a
        // picked iCloud Keychain passkey to iCloud Keychain alone.
        if #available(macOS 14.4, *), body["platformOnly"] as? Bool != true {
            let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialAssertionRequest(clientData: clientData)
            key.allowedCredentials = allowed.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: $0.transports)
            }
            key.userVerificationPreference = verification
            // A key registered through U2F signs for its AppID, not the RP ID
            // (GitHub's and Google's older security keys).
            if let appid = body["appid"] as? String, !appid.isEmpty { key.appID = appid }
            if #available(macOS 26.4, *) { key.prf = prf }
            requests.append(key)
        }
        return requests
    }

    private func registration(_ body: [String: Any], rp: String, clientData: ASPublicKeyCredentialClientData) -> [ASAuthorizationRequest]? {
        guard let user = body["user"] as? [String: Any],
              let userID = Passkeys.data(user["id"]), (1...64).contains(userID.count),
              let name = user["name"] as? String
        else { return nil }
        let display = (user["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let verification = Passkeys.verification(body["userVerification"])
        let attestation = Passkeys.attestation(body["attestation"])
        let excluded = Passkeys.descriptors(body["excludeCredentials"])
        let attachment = body["authenticatorAttachment"] as? String
        // No list means ES256 or RS256, as the standard has it.
        let algorithms = (body["algorithms"] as? [Int]).flatMap { $0.isEmpty ? nil : $0 } ?? [-7, -257]
        var requests: [ASAuthorizationRequest] = []

        // A passkey from the Mac is always ES256: offered only to a site that takes it.
        if attachment != "cross-platform", algorithms.contains(-7) {
            let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialRegistrationRequest(clientData: clientData, name: name, userID: userID)
            platform.displayName = display
            platform.userVerificationPreference = verification
            platform.attestationPreference = attestation
            platform.prf = Passkeys.prfRegistration(body["prf"])
            platform.largeBlob = Passkeys.largeBlobRegistration(body["largeBlob"])
            if #available(macOS 14.4, *) {
                platform.excludedCredentials = excluded.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0.id) }
            }
            requests.append(platform)
        }
        // A blob the site requires is the Mac's passkeys' alone: a security
        // key here can't be asked for one, so it isn't offered.
        let blobRequired = (body["largeBlob"] as? [String: Any])?["support"] as? String == "required"
        if attachment != "platform", !blobRequired, #available(macOS 14.4, *) {
            let key = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rp)
                .createCredentialRegistrationRequest(clientData: clientData, displayName: display, name: name, userID: userID)
            key.credentialParameters = algorithms.map {
                ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0))
            }
            key.userVerificationPreference = verification
            key.attestationPreference = attestation
            switch body["residentKey"] as? String {
            case "required": key.residentKeyPreference = .required
            case "preferred": key.residentKeyPreference = .preferred
            default: key.residentKeyPreference = .discouraged
            }
            key.excludedCredentials = excluded.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0.id, transports: $0.transports)
            }
            if #available(macOS 26.4, *) { key.prf = Passkeys.prfRegistration(body["prf"]) }
            requests.append(key)
        }
        return requests
    }

    /// The extension whose page this is, by its origin, and which sites it
    /// may name: those its manifest asks for and Settings hasn't refused it,
    /// never an address or a suffix anyone can register under.
    static func extensionPage(for origin: WKSecurityOrigin) -> ExtensionPage? {
        let scheme = origin.protocol.lowercased(), host = origin.host.lowercased()
        guard scheme != "https", scheme != "http", !host.isEmpty else { return nil }
        for extensions in Extensions.all {
            for (id, context) in extensions.contexts
            where context.baseURL.scheme?.lowercased() == scheme && context.baseURL.host?.lowercased() == host {
                return ExtensionPage(origin: "chrome-extension://\(id)") { [weak context] rp in
                    guard let context, rp.contains("."), !rp.contains(":"), !rp.allSatisfy({ $0.isNumber || $0 == "." }),
                          Vault.publicSuffix.map({ !$0(rp as CFString) }) ?? false,
                          let url = URL(string: "https://\(rp)/")
                    else { return false }
                    return context.permissionStatus(for: url) != .deniedExplicitly
                        && context.webExtension.allRequestedMatchPatterns.contains { $0.matches(url) }
                }
            }
        }
        return nil
    }

    // MARK: - PRF

    /// The salts a page gave for PRF, raw: macOS hashes them as WebAuthn
    /// says, as it does for Safari. One pair for any credential, or one per
    /// credential by its ID.
    private static func prfValues(_ value: Any?) -> ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues? {
        guard let pair = value as? [String: Any], let first = data(pair["first"]) else { return nil }
        return .saltInput1(first, saltInput2: data(pair["second"]))
    }

    static func prfAssertion(_ value: Any?) -> ASAuthorizationPublicKeyCredentialPRFAssertionInput? {
        guard let prf = value as? [String: Any] else { return nil }
        var each: [Data: ASAuthorizationPublicKeyCredentialPRFAssertionInput.InputValues] = [:]
        for (id, pair) in prf["byCredential"] as? [String: Any] ?? [:] {
            if let id = data(id), let values = prfValues(pair) { each[id] = values }
        }
        if let values = prfValues(prf["eval"]) { return .inputValues(values, perCredentialInputValues: each.isEmpty ? nil : each) }
        return each.isEmpty ? nil : .perCredentialInputValues(each)
    }

    static func prfRegistration(_ value: Any?) -> ASAuthorizationPublicKeyCredentialPRFRegistrationInput? {
        guard let prf = value as? [String: Any] else { return nil }
        return prfValues(prf["eval"]).map { .inputValues($0) } ?? .checkForSupport
    }

    // MARK: - largeBlob

    /// A create's largeBlob support ("required" or "preferred"), as macOS
    /// takes it for a passkey of its own.
    static func largeBlobRegistration(_ value: Any?) -> ASAuthorizationPublicKeyCredentialLargeBlobRegistrationInput? {
        switch (value as? [String: Any])?["support"] as? String {
        case "required": return .supportRequired
        case "preferred": return .supportPreferred
        default: return nil
        }
    }

    /// A get's largeBlob: read the blob, or write the one given.
    static func largeBlobAssertion(_ value: Any?) -> ASAuthorizationPublicKeyCredentialLargeBlobAssertionInput? {
        guard let asked = value as? [String: Any] else { return nil }
        if asked["read"] as? Bool == true { return .read }
        if let blob = data(asked["write"]) { return .write(blob) }
        return nil
    }

    /// What macOS says of the blob: read (its bytes, or none kept) or written.
    static func largeBlobReply(_ output: ASAuthorizationPublicKeyCredentialLargeBlobAssertionOutput) -> [String: Any] {
        switch output.result {
        case .read(data: let blob): return blob.map { ["blob": text($0)] } ?? [:]
        case .write(success: let success): return ["written": success]
        @unknown default: return [:]
        }
    }

    static func prfReply(first: SymmetricKey?, second: SymmetricKey?, enabled: Bool?) -> [String: Any] {
        var reply: [String: Any] = [:]
        if let enabled { reply["enabled"] = enabled }
        if let first { reply["first"] = text(first.withUnsafeBytes { Data($0) }) }
        if let second { reply["second"] = text(second.withUnsafeBytes { Data($0) }) }
        return reply
    }

    // MARK: - answers

    private func finish(_ value: [String: Any]) {
        let answer = self.answer
        clear()
        answer?(value)
    }

    private func clear() {
        controller = nil
        token = nil
        answer = nil
    }

    private func refuse(_ answer: ([String: Any]) -> Void, _ name: String, _ message: String) {
        Passkeys.note("refused \(name): \(message); \(Passkeys.windows())")
        answer(Passkeys.failure(name, message))
    }

    private static func failure(_ name: String, _ message: String) -> [String: Any] {
        ["error": name, "message": message]
    }

    /// A security key's credential that a site named, not one it keeps for
    /// the account, has no user handle: the page hears null.
    static func assertionReply(id: Data, clientData: Data, authenticatorData: Data, signature: Data, user: Data?, attachment: String) -> [String: Any] {
        var reply: [String: Any] = [
            "kind": "get", "id": text(id), "clientDataJSON": text(clientData),
            "authenticatorData": text(authenticatorData), "signature": text(signature), "attachment": attachment,
        ]
        if let user, !user.isEmpty { reply["userHandle"] = text(user) }
        return reply
    }

    static func registrationReply(id: Data, clientData: Data, attestation: Data, transports: [String], attachment: String) -> [String: Any] {
        var reply: [String: Any] = [
            "kind": "create", "id": text(id), "clientDataJSON": text(clientData),
            "attestationObject": text(attestation), "transports": transports, "attachment": attachment,
        ]
        if let data = authenticatorData(inAttestation: attestation) {
            reply["authenticatorData"] = text(data)
            if let key = publicKey(inAuthenticatorData: data) {
                reply["publicKeyAlgorithm"] = key.algorithm
                if let der = key.der { reply["publicKey"] = text(der) }
            }
        }
        return reply
    }

    /// For a test run: a credential in the shape the sheet gives, made up
    /// from the request, a P-256 key and all, with nothing signed.
    static func rehearsal(_ kind: String, rp: String, origin: String, challenge: Data, crossOrigin topOrigin: String? = nil,
                          id picked: Data? = nil) -> [String: Any] {
        let cross = topOrigin.map { #","crossOrigin":true,"topOrigin":"\#($0)""# } ?? #","crossOrigin":false"#
        let client = Data(#"{"type":"webauthn.\#(kind)","challenge":"\#(text(challenge))","origin":"\#(origin)"\#(cross)}"#.utf8)
        let id = picked ?? Data((0..<16).map { UInt8($0) })
        // The relying party's hash, then the flags and the count.
        var auth = Data(SHA256.hash(data: Data(rp.utf8))) + Data([kind == "get" ? 0x05 : 0x45]) + Data(count: 4)
        guard kind == "create" else {
            return assertionReply(id: id, clientData: client, authenticatorData: auth, signature: Data([0x30, 0]), user: Data("user".utf8), attachment: "platform")
        }
        auth += Data(count: 16) + Data([0, UInt8(id.count)]) + id
        // A real P-256 point: Chromium parses the key and its DER must match.
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        auth += Data([0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]) + point[1..<33]
        auth += Data([0x22, 0x58, 0x20]) + point[33..<65]
        var object = Data([0xA3, 0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        object += Data([0x67]) + Data("attStmt".utf8) + Data([0xA0])
        // Shortest-form length, as CBOR's canonical form has it: Chromium's
        // reader refuses any other.
        let length = auth.count < 256 ? Data([0x58, UInt8(auth.count)]) : Data([0x59, UInt8(auth.count >> 8), UInt8(auth.count & 0xFF)])
        object += Data([0x68]) + Data("authData".utf8) + length + auth
        return registrationReply(id: id, clientData: client, attestation: object, transports: ["hybrid", "internal"], attachment: "platform")
    }

    // MARK: - checks

    /// The relying party is the page's own host, or a domain above it that is
    /// still a site of its own: never another site, never an address, and
    /// never a suffix anyone can register under, com, co.uk, github.io.
    static func fits(_ rp: String, _ host: String) -> Bool {
        if rp == host { return true }
        let address = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        guard !address, host.hasSuffix("." + rp), rp.contains("."), let suffix = Vault.publicSuffix else { return false }
        return !suffix(rp as CFString)
    }

    // MARK: - bytes

    static func data(_ value: Any?) -> Data? {
        guard var text = value as? String else { return nil }
        text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    static func text(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func descriptors(_ value: Any?) -> [(id: Data, transports: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport])] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let id = data(item["id"]) else { return nil }
            let named = (item["transports"] as? [String] ?? []).compactMap { name -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
                switch name {
                case "usb": return .usb
                case "nfc": return .nfc
                case "ble": return .bluetooth
                default: return nil
                }
            }
            return (id, named.isEmpty ? ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported : named)
        }
    }

    private static func verification(_ value: Any?) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch value as? String {
        case "required": return .required
        case "discouraged": return .discouraged
        default: return .preferred
        }
    }

    private static func attestation(_ value: Any?) -> ASAuthorizationPublicKeyCredentialAttestationKind {
        switch value as? String {
        case "direct": return .direct
        case "indirect": return .indirect
        case "enterprise": return .enterprise
        default: return .none
        }
    }

    /// The authenticator data inside an attestation object, a CBOR map with
    /// it under "authData", for the pages that ask for it directly.
    static func authenticatorData(inAttestation object: Data) -> Data? {
        var reader = CBOR(bytes: [UInt8](object))
        guard let pairs = reader.mapCount() else { return nil }
        for _ in 0..<pairs {
            guard let key = reader.text() else { return nil }
            if key == "authData" { return reader.blob().map { Data($0) } }
            guard reader.skip() else { return nil }
        }
        return nil
    }

    /// The new credential's public key, from its authenticator data: the
    /// algorithm, and the key as getPublicKey() hands it over, DER, for the
    /// two kinds passkeys and security keys make, P-256 and Ed25519. For any
    /// other the site reads it out of the attestation object itself.
    static func publicKey(inAuthenticatorData data: Data) -> (algorithm: Int, der: Data?)? {
        let bytes = [UInt8](data)
        // The relying party's hash, the flags, with a credential in it, the
        // count, the model's ID, and the credential ID's length.
        guard bytes.count > 55, bytes[32] & 0x40 != 0 else { return nil }
        let start = 55 + (Int(bytes[53]) << 8 | Int(bytes[54]))
        guard start < bytes.count else { return nil }
        var reader = CBOR(bytes: Array(bytes[start...]))
        guard let pairs = reader.mapCount() else { return nil }
        var fields: [Int: Any] = [:]
        for _ in 0..<pairs {
            guard let key = reader.int() else { return nil }
            switch reader.major {
            case 0, 1: fields[key] = reader.int()
            case 2: fields[key] = reader.blob()
            default: guard reader.skip() else { return nil }
            }
        }
        guard let algorithm = fields[3] as? Int else { return nil }
        let x = fields[-2] as? [UInt8]
        switch (fields[1] as? Int, fields[-1] as? Int) {
        case (2, 1):
            guard let x, x.count == 32, let y = fields[-3] as? [UInt8], y.count == 32 else { return (algorithm, nil) }
            let head: [UInt8] = [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04,
            ]
            return (algorithm, Data(head + x + y))
        case (1, 6):
            guard let x, x.count == 32 else { return (algorithm, nil) }
            return (algorithm, Data([0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00] + x))
        default:
            return (algorithm, nil)
        }
    }
}

extension Passkeys: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let window = anchor ?? NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
        Passkeys.note("anchor \(anchor == nil ? "fallback" : "caller's") \(Passkeys.describe(window))")
        return window
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Passkeys.note("didComplete \(type(of: authorization.credential)) current=\(controller === self.controller)")
        guard controller === self.controller else { return }
        let credential = authorization.credential
        // AuthenticationServices' headers say nothing of nil, so each of
        // these is Data! to Swift; a security key leaves userID nil, and
        // reading it straight brought the app down (#1032).
        if let got = credential as? ASAuthorizationPublicKeyCredentialAssertion,
           let id = got.credentialID as Data?, let client = got.rawClientDataJSON as Data?,
           let auth = got.rawAuthenticatorData as Data?, let signature = got.signature as Data? {
            let attachment = (credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion)?.attachment
            Passkeys.log.notice("signed in")
            var reply = Passkeys.assertionReply(
                id: id, clientData: client, authenticatorData: auth,
                signature: signature, user: got.userID as Data?,
                attachment: attachment == .platform ? "platform" : "cross-platform"
            )
            var prf = (credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion)?.prf
            if #available(macOS 26.4, *), prf == nil { prf = (credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion)?.prf }
            if let prf { reply["prf"] = Passkeys.prfReply(first: prf.first, second: prf.second, enabled: nil) }
            if let blob = (credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion)?.largeBlob {
                reply["largeBlob"] = Passkeys.largeBlobReply(blob)
            }
            if let key = credential as? ASAuthorizationSecurityKeyPublicKeyCredentialAssertion { reply["appid"] = key.appID }
            finish(reply)
        } else if let made = credential as? ASAuthorizationPublicKeyCredentialRegistration,
                  let id = made.credentialID as Data?, let client = made.rawClientDataJSON as Data? {
            let platform = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration
            Passkeys.log.notice("made one")
            var reply = Passkeys.registrationReply(
                id: id, clientData: client, attestation: made.rawAttestationObject ?? Data(),
                transports: platform == nil ? ["usb"] : ["hybrid", "internal"],
                attachment: platform?.attachment == .platform ? "platform" : "cross-platform"
            )
            var prf = platform?.prf
            if #available(macOS 26.4, *), prf == nil { prf = (credential as? ASAuthorizationSecurityKeyPublicKeyCredentialRegistration)?.prf }
            if let prf { reply["prf"] = Passkeys.prfReply(first: prf.first, second: prf.second, enabled: prf.isSupported) }
            if let blob = platform?.largeBlob { reply["largeBlob"] = ["supported": blob.isSupported] }
            finish(reply)
        } else {
            finish(Passkeys.failure("NotAllowedError", "The authenticator answered with something else."))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Passkeys.note("didCompleteWithError \((error as NSError).domain) \((error as NSError).code) current=\(controller === self.controller); \(Passkeys.windows())")
        guard controller === self.controller else { return }
        Passkeys.log.notice("failed: \(String(describing: error), privacy: .public)")
        // A credential it already holds is what a site is told; anything else
        //, no, the sheet closed, the time ran out, a site may not tell apart.
        if (error as NSError).domain == ASAuthorizationError.errorDomain, (error as NSError).code == 1006 {
            finish(Passkeys.failure("InvalidStateError", "The authenticator already holds a credential for this account."))
        } else {
            finish(Passkeys.failure("NotAllowedError", "The operation either timed out or was not allowed."))
        }
    }
}

/// Just enough CBOR to read an attestation object: maps, numbers, text and
/// byte strings, and a step over anything else.
private struct CBOR {
    let bytes: [UInt8]
    var at = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var major: UInt8? { at < bytes.count ? bytes[at] >> 5 : nil }

    private mutating func head() -> (major: UInt8, value: UInt64)? {
        guard at < bytes.count else { return nil }
        let first = bytes[at]
        at += 1
        let info = first & 0x1F
        switch info {
        case 0..<24:
            return (first >> 5, UInt64(info))
        case 24...27:
            let size = 1 << Int(info - 24)
            guard at + size <= bytes.count else { return nil }
            let value = bytes[at..<(at + size)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            at += size
            return (first >> 5, value)
        default:
            return nil
        }
    }

    mutating func mapCount() -> Int? {
        guard let (major, value) = head(), major == 5, value < 1024 else { return nil }
        return Int(value)
    }

    mutating func int() -> Int? {
        guard let (major, value) = head(), value < UInt64(Int.max) else { return nil }
        switch major {
        case 0: return Int(value)
        case 1: return -1 - Int(value)
        default: return nil
        }
    }

    mutating func text() -> String? {
        guard let (major, value) = head(), major == 3, value <= UInt64(bytes.count - at) else { return nil }
        defer { at += Int(value) }
        return String(bytes: bytes[at..<(at + Int(value))], encoding: .utf8)
    }

    mutating func blob() -> [UInt8]? {
        guard let (major, value) = head(), major == 2, value <= UInt64(bytes.count - at) else { return nil }
        defer { at += Int(value) }
        return Array(bytes[at..<(at + Int(value))])
    }

    mutating func skip(depth: Int = 0) -> Bool {
        guard depth < 16, let (major, value) = head() else { return false }
        switch major {
        case 0, 1, 7:
            return true
        case 2, 3:
            guard value <= UInt64(bytes.count - at) else { return false }
            at += Int(value)
            return true
        case 4:
            guard value < 1024 else { return false }
            return (0..<value).allSatisfy { _ in skip(depth: depth + 1) }
        case 5:
            guard value < 1024 else { return false }
            return (0..<value).allSatisfy { _ in skip(depth: depth + 1) && skip(depth: depth + 1) }
        case 6:
            return skip(depth: depth + 1)
        default:
            return false
        }
    }
}

/// Requests that wait on the Mac's passkey question (Passkeys.ensure), and
/// which of them starts once it is answered. Before, every one started, one
/// after another in the same moment, each ending the one before: three
/// sheets opened and closed back to back, Touch ID armed each time, when a
/// page asked twice while the question was up (farm 2e824d3955444462, adhd).
/// And only the last one its page called off was remembered, so the others
/// still brought up the sheet over a page that had given up on them
/// (feedback #1843). Now the newest one still wanted starts, alone, as a
/// newer request ends the one before in any browser; the others hear so,
/// and every one called off hears it was.
struct PasskeyWaits {
    enum Turn: Equatable { case start, aborted, superseded }

    private(set) var serial = 0
    private var withdrawn: Set<String> = []

    /// A request on its way to the question: its place in line.
    mutating func asked() -> Int {
        serial += 1
        return serial
    }

    /// Called off by its page before it could start.
    mutating func withdraw(_ token: String) { withdrawn.insert(token) }

    /// Its turn, the question answered: started only if it is the newest
    /// and still wanted.
    mutating func turn(_ ask: Int, token: String?) -> Turn {
        if let token, withdrawn.remove(token) != nil { return .aborted }
        return ask == serial ? .start : .superseded
    }
}

/// The page's side: requests handed over, answers handed back.
final class PasskeyRelay: NSObject, WKScriptMessageHandlerWithReply, PageScriptReplying {
    static let name = "yabPasskeys"

    weak var tab: Tab?
    /// The page's word to yab's side, and the answer back (see `bridge`).
    static let asked = "yab-passkeys-ask"
    static let answered = "yab-passkeys-answer"

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            let origin = message.frameInfo.securityOrigin
            let caller = Passkeys.Caller(
                origin: PageOrigin(origin),
                mainFrame: message.frameInfo.isMainFrame,
                pageHost: message.webView?.url?.host(),
                window: message.webView?.window,
                extensionPage: Passkeys.extensionPage(for: origin)
            )
            // A popup closes as the Mac's sheet takes the focus, and the
            // answer would have nowhere to go: held open until it comes.
            handle(message.body, caller: caller, hold: { message.webView.flatMap(ExtensionPopup.hold) }, replyHandler)
        }
    }

    /// A Chromium page's word that it wanted a passkey where there are none
    /// to give (PasskeyHint, forms-without-passkeys.js), and nothing else:
    /// its passkey requests reach Yab only from Chromium, once Chromium has
    /// checked them (ChromiumWebAuthn), never from a page script's event.
    func receive(_ message: PageScriptMessage, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], body["kind"] as? String == "missing" else {
                return reply(nil, "Chromium pages ask for passkeys through Chromium")
            }
            let caller = Passkeys.Caller(origin: message.frame.origin, mainFrame: message.frame.isMain,
                                         pageHost: nil, window: message.sourceView?.window)
            handle(body, caller: caller, hold: { nil }, reply)
        }
    }

    @MainActor
    private func handle(_ message: Any, caller: Passkeys.Caller, hold: () -> (() -> Void)?,
                        _ replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message as? [String: Any] else { return replyHandler(nil, "Not a request") }
        let kind = body["kind"] as? String
        Passkeys.note("asked \(kind ?? "?") by \(caller.origin.scheme)://\(caller.origin.host) main=\(caller.mainFrame) window=\(Passkeys.describe(caller.window))")
        if kind == "cancel" {
            Passkeys.shared.cancel(token: body["token"] as? String)
            return replyHandler(true, nil)
        }
        // A page that wanted a passkey where there are none to give
        // (PasskeyHint): told, and nothing else. Asked of a build without
        // the entitlement, a request is that too, and goes on as asked.
        if kind == "missing" || ((kind == "get" || kind == "create") && !PasskeyHint.possible),
           let tab, let ask = kind == "missing" ? PasskeyHint.Ask(rawValue: body["ask"] as? String ?? "") : .request {
            tab.onPasskeysMissing?(tab, ask)
        }
        if kind == "missing" { return replyHandler(true, nil) }
        // The same request heard twice, by yab's bridge and an extension
        // page's both (PasskeyRelay.install): one ceremony, one answer
        // for each. The page takes the first and lets the other go.
        let token = body["token"] as? String
        if let token, PasskeyRelay.inFlight[token] != nil {
            PasskeyRelay.inFlight[token]?.append { replyHandler($0, nil) }
            return
        }
        if let token { PasskeyRelay.inFlight[token] = [] }
        let popup = hold()
        Passkeys.shared.perform(body, from: caller) { reply in
            popup?()
            replyHandler(reply, nil)
            let others = token.flatMap { PasskeyRelay.inFlight.removeValue(forKey: $0) } ?? []
            others.forEach { $0(reply) }
        }
    }

    /// An extension's own pages, its popup, a window of its own, share one
    /// configuration: the patch and its bridge both in the page's world,
    /// which is the extension's own, where its WebAuthn is answered.
    /// Bitwarden unlocks its vault from its popup with a passkey's PRF.
    ///
    /// By a name of its own: a tab showing an extension's page shares this
    /// controller, and takes its own relays' names off it (Web.release).
    static let extensionName = "yabExtensionPasskeys"

    nonisolated(unsafe) private static var relayKey: UInt8 = 0

    /// Requests on their way, by token, and whoever else asked the same.
    @MainActor static var inFlight: [String: [(Any?) -> Void]] = [:]

    @MainActor private static let extensionScripts = [bridging(extensionName), page].map {
        WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// Again as a popup or a window of the extension's opens: a tab showing
    /// one of its pages arms the same controller with a tab's scripts, and
    /// those go in place of everything there (PageScripts.fit).
    @MainActor static func install(in controller: WKUserContentController) {
        // Once a controller: its handler stays through a tab's arming, and
        // taken off, it would drop an answer still on its way.
        if objc_getAssociatedObject(controller, &relayKey) == nil {
            let relay = PasskeyRelay()
            controller.addScriptMessageHandler(relay, contentWorld: .page, name: extensionName)
            objc_setAssociatedObject(controller, &relayKey, relay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let have = Set(controller.userScripts.map(ObjectIdentifier.init))
        for script in extensionScripts where !have.contains(ObjectIdentifier(script)) { controller.addUserScript(script) }
    }

    /// In the page, before anything of the site's runs: navigator.credentials
    /// answers requests for a public key from here, and anything else it is
    /// asked, a stored password, as it always did. On the prototype: WebKit
    /// makes navigator.credentials anew whenever nothing holds it, and what
    /// was set on the old one goes with it.
    ///
    /// It has to be in the page's own world to stand in for the page's
    /// functions, and nothing of yab's is there for a page to find, no
    /// window.webkit, no global of its own. Requests go to yab's side as
    /// events on the window (see `bridge`).
    static let page = PageScript.load("passkeys-page", vars: ["ANSWERED": answered, "ASKED": asked, "OTHER_SITES": "engine"])

    /// yab's side of it, in yab's own world (Web.world), where the
    /// handler is and a page can't look. A request the page dispatches is
    /// handed over as it is, the frame it comes from is WebKit's to say, not
    /// the event's, and the answer dispatched back for the page to pick up.
    static let bridge = bridging(name)

    static func bridging(_ name: String) -> String { """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__yabBridged) return;
      window.__yabBridged = true;
      window.addEventListener('\(asked)', function (event) {
        var message;
        try { message = JSON.parse(event.detail); } catch (e) { return; }
        if (!message || typeof message !== 'object' || typeof message.token !== 'string') return;
        function answer(reply) {
          window.dispatchEvent(new CustomEvent('\(answered)', { detail: JSON.stringify({ token: message.token, reply: reply }) }));
        }
        var quiet = message.kind === 'cancel' || message.kind === 'missing';
        handler.postMessage(message).then(function (reply) {
          if (!quiet) answer(reply);
        }, function () {
          if (!quiet) answer(null);
        });
      });
    })();
    """ }
}
