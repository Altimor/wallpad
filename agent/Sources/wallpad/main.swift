// Wallpad: lets a phone on the office Wi-Fi drive this Mac (the one plugged into a TV) like an
// Apple TV remote: a big trackpad, a keyboard, modifier / media / function keys.
//
//   wallpad setup [--name "Lobby TV"]   first run: creates the QR secret, writes the QR card to the Desktop
//   wallpad qr                          writes the QR card again
//   wallpad                             runs the agent (a LaunchAgent, see scripts/install.sh)
//
// The QR code points at http://<this Mac>.local:8765/#<secret>. The .local name is announced on the network
// by macOS itself (Bonjour), so printed codes keep working when the Mac's IP changes, and no server is needed.
//
// Security model:
//   - the QR code holds a per-TV secret; without it the WebSocket accepts nothing
//   - a phone seen for the first time must also type a 4-digit code shown on the TV (so a photo of the
//     QR code isn't enough); it's then remembered for 30 days
//   - self-updates (from GitHub Releases) are installed only if signed by the same developer team

import AppKit
import CommonCrypto
import CoreImage
import Network
import Security
import SystemConfiguration

/// Where updates come from (GitHub owner/repo, set by scripts/package.sh).
let releasesRepo = Bundle.main.object(forInfoDictionaryKey: "WallpadRepo") as? String ?? "Altimor/wallpad"
/// WALLPAD_HOME: a scratch home for testing (config + QR card go there instead of the real one)
let home = ProcessInfo.processInfo.environment["WALLPAD_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
let supportDir = home.appendingPathComponent("Library/Application Support/Wallpad")
let configURL = supportDir.appendingPathComponent("config.json")
let devicesURL = supportDir.appendingPathComponent("devices.json")
let pairingDays = 30.0

struct Config: Codable {
    var name: String
    var token: String
    var port: UInt16 = 8765
    var wsPort: UInt16 { port + 1 }
    var qrURL: String { "http://\(LAN.hostname):\(port)/#\(token)" }
}

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

/// Cryptographically random (SystemRandomNumberGenerator is backed by the OS CSPRNG).
func randomString(_ n: Int, _ alphabet: String = "abcdefghijkmnpqrstuvwxyz23456789") -> String {
    var rng = SystemRandomNumberGenerator()
    let chars = Array(alphabet)
    return String((0..<n).map { _ in chars.randomElement(using: &rng)! })
}

func sha256(_ s: String) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let d = Data(s.utf8)
    d.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(d.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Constant-time comparison for secrets.
func secretEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

func loadConfig() -> Config? {
    // installs from before the rename kept their config under "tv-remote"
    let legacy = home.appendingPathComponent("Library/Application Support/tv-remote")
    if !FileManager.default.fileExists(atPath: supportDir.path), FileManager.default.fileExists(atPath: legacy.appendingPathComponent("config.json").path) {
        try? FileManager.default.moveItem(at: legacy, to: supportDir)
    }
    guard let d = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: d)
}

func saveConfig(_ c: Config) throws {
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir.path)
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(c).write(to: configURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
}

// MARK: - paired phones

/// Phones that typed the TV's code, by hash of their device token → expiry.
enum Devices {
    static var all: [String: Double] = {
        guard let d = try? Data(contentsOf: devicesURL), let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m
    }()

    static func isValid(_ token: String) -> Bool {
        guard token.count >= 32, let exp = all[sha256(token)] else { return false }
        return exp > Date().timeIntervalSince1970
    }

    static func add() -> String {
        let token = randomString(40, "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let now = Date().timeIntervalSince1970
        all = all.filter { $0.value > now }
        all[sha256(token)] = now + pairingDays * 86400
        if let d = try? JSONEncoder().encode(all) {
            try? d.write(to: devicesURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesURL.path)
        }
        return token
    }
}

/// The pairing code, shown big on the TV while a new phone is pairing.
final class CodeOverlay {
    static let shared = CodeOverlay()
    var window: NSWindow?

    func show(_ code: String, tv: String) {
        if Input.dryRun { log("pairing code \(code)"); return }
        hide()
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = Self.view(code, tv: tv, size: screen.frame.size)
        w.orderFrontRegardless()
        window = w
    }

    static func view(_ code: String, tv: String, size: NSSize) -> NSView {
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        let card = NSView(frame: NSRect(x: (size.width - 760) / 2, y: (size.height - 420) / 2, width: 760, height: 420))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.96).cgColor
        card.layer?.cornerRadius = 40
        func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat, mono: Bool = false) {
            let l = NSTextField(labelWithString: s)
            l.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
            l.textColor = color
            l.alignment = .center
            l.frame = NSRect(x: 0, y: y, width: 760, height: size * 1.3)
            card.addSubview(l)
        }
        label("Wallpad · \(tv)", 34, .medium, NSColor(white: 0.65, alpha: 1), y: 320)
        label(code.map(String.init).joined(separator: " "), 150, .semibold, .white, y: 120, mono: true)
        label("Type this code on your phone", 34, .regular, NSColor(white: 0.65, alpha: 1), y: 55)
        v.addSubview(card)
        return v
    }

    func hide() { window?.orderOut(nil); window = nil }
}

// MARK: - input injection

enum Input {
    static var buttonDown = false
    static var lastClick: (time: TimeInterval, count: Int) = (0, 0)
    static let source = CGEventSource(stateID: .hidSystemState)

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Modifiers held on the remote (control / option / command), applied to every event.
    static var flags: CGEventFlags = []

    static func post(_ e: CGEvent?) {
        guard let e else { return }
        if !flags.isEmpty { e.flags = e.flags.union(flags) }
        e.post(tap: .cghidEventTap)
    }

    /// The union of all displays, in global (top-left origin) coordinates.
    static var desktop: CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }

    static func move(_ dx: Double, _ dy: Double) {
        let d = desktop
        var p = location
        p.x = min(max(p.x + dx, d.minX), d.maxX - 1)
        p.y = min(max(p.y + dy, d.minY), d.maxY - 1)
        let type: CGEventType = buttonDown ? .leftMouseDragged : .mouseMoved
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left))
    }

    static func click(right: Bool) {
        let p = location
        let now = ProcessInfo.processInfo.systemUptime
        // successive taps become double / triple clicks, as with a real mouse
        let count = (!right && now - lastClick.time < NSEvent.doubleClickInterval) ? min(lastClick.count + 1, 3) : 1
        lastClick = (now, count)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for t in [down, up] {
            let e = CGEvent(mouseEventSource: source, mouseType: t, mouseCursorPosition: p, mouseButton: button)
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            post(e)
        }
    }

    static func press(_ down: Bool) {
        buttonDown = down
        post(CGEvent(mouseEventSource: source, mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: location, mouseButton: .left))
    }

    static func scroll(_ dx: Double, _ dy: Double) {
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0))
    }

    static func type(_ text: String) {
        for ch in text {
            if ch == "\n" { key("return"); continue }
            // with a modifier held, send the real key so shortcuts (⌘C, ⌃A…) work
            if !flags.isEmpty, let code = letterCodes[Character(ch.lowercased())] {
                for down in [true, false] { post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)) }
                continue
            }
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(e)
            }
        }
    }

    static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "space": 49, "backspace": 51, "esc": 53, "delete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "mission": 160, "launchpad": 131,
    ]
    /// US layout key codes, for typed characters while a modifier is held.
    static let letterCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    /// NX_KEYTYPE_* media keys (sent as system-defined events, like the keyboard's top row).
    static let mediaKeys: [String: Int] = [
        "volup": 0, "voldown": 1, "brightup": 2, "brightdown": 3, "mute": 7, "playpause": 16, "next": 17, "previous": 18,
    ]

    static func key(_ name: String, modifiers: [String] = []) {
        if let m = mediaKeys[name] { media(m); return }
        guard let code = keyCodes[name] else { return }
        let held = flags
        flags.formUnion(parse(modifiers))
        for down in [true, false] { post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)) }
        flags = held
    }

    static func parse(_ names: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in names {
            switch m {
            case "cmd": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "alt": f.insert(.maskAlternate)
            case "ctrl": f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    static func media(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (key << 16) | ((down ? 0xa : 0xb) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    static let dryRun = ProcessInfo.processInfo.environment["WALLPAD_DRYRUN"] != nil   // log instead of moving / typing

    static func handle(_ m: [String: Any]) {
        if dryRun { log("event \(m)"); return }
        let num = { (k: String) in (m[k] as? NSNumber)?.doubleValue ?? 0 }
        flags = parse(m["mods"] as? [String] ?? [])
        defer { flags = [] }
        switch m["t"] as? String {
        case "move": move(num("dx"), num("dy"))
        case "click": click(right: (m["b"] as? String) == "right")
        case "down": press(true)
        case "up": press(false)
        case "scroll": scroll(num("dx"), num("dy"))
        case "text": type(m["s"] as? String ?? "")
        case "key": key(m["k"] as? String ?? "")
        default: break
        }
    }
}

// MARK: - local network: the remote page (HTTP) and its WebSocket

final class Server {
    let config: Config
    let queue = DispatchQueue(label: "wallpad")
    var http: NWListener!
    var ws: NWListener!
    var page: Data

    init(config: Config) throws {
        self.config = config
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [exe.appendingPathComponent("../Resources/remote.html"), exe.appendingPathComponent("remote.html"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("remote.html")]
        guard let html = candidates.lazy.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first else {
            throw NSError(domain: "wallpad", code: 1, userInfo: [NSLocalizedDescriptionKey: "remote.html not found next to the binary"])
        }
        page = Data(html.replacingOccurrences(of: "{{NAME}}", with: config.name.replacingOccurrences(of: "<", with: "&lt;"))
                        .replacingOccurrences(of: "{{WSPORT}}", with: String(config.wsPort)).utf8)
        http = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.port)!)
        let p = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        p.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        ws = try NWListener(using: p, on: NWEndpoint.Port(rawValue: config.wsPort)!)
    }

    func start() {
        http.newConnectionHandler = { [weak self] c in self?.serveHTTP(c) }
        ws.newConnectionHandler = { [weak self] c in self?.serveWS(c) }
        http.start(queue: queue)
        ws.start(queue: queue)
        log("remote on http://\(LAN.localIPv4() ?? "?"):\(config.port) (ws :\(config.wsPort))")
    }

    func serveHTTP(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let parts = req.split(separator: " ")
            let method = parts.first.map(String.init) ?? "GET", path = parts.dropFirst().first.map(String.init) ?? "/"
            var extra = ""
            let (status, type, body): (String, String, Data)
            if method == "GET", path == "/" || path.hasPrefix("/?") {
                (status, type, body) = ("200 OK", "text/html; charset=utf-8", self.page)
            } else if method == "POST", path.hasPrefix("/remember?d=") {
                // a paired phone's device token as a cookie: set by the server, so Safari keeps it for its full
                // lifetime (cookies written by scripts are capped at 7 days)
                let token = String(path.dropFirst("/remember?d=".count))
                if Devices.isValid(token) {
                    extra = "Set-Cookie: wallpad_device=\(token); Max-Age=\(Int(pairingDays * 86400)); Path=/; SameSite=Strict\r\n"
                    (status, type, body) = ("204 No Content", "text/plain", Data())
                } else {
                    (status, type, body) = ("403 Forbidden", "text/plain", Data("unknown device".utf8))
                }
            } else {
                (status, type, body) = ("404 Not Found", "text/plain", Data("not found".utf8))
            }
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\(extra)"
            head += "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    /// The connection currently pairing (only one at a time; a newer one takes over the code on screen).
    var pairing: (conn: NWConnection, code: String, tries: Int)?

    func endPairing(_ c: NWConnection) {
        guard pairing?.conn === c else { return }
        pairing = nil
        DispatchQueue.main.async { CodeOverlay.shared.hide() }
    }

    func serveWS(_ c: NWConnection) {
        var authed = false
        func next() {
            c.receiveMessage { data, ctx, _, err in
                if err != nil { self.endPairing(c); c.cancel(); return }
                if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata, meta.opcode == .close {
                    self.endPairing(c); c.cancel(); return
                }
                guard let data, let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { next(); return }
                if authed { DispatchQueue.main.async { Input.handle(m) }; next(); return }
                switch m["t"] as? String {
                case "auth":
                    // the secret from the QR code (URL fragment) must come first
                    guard secretEquals(m["token"] as? String ?? "", self.config.token) else {
                        self.reply(c, ["t": "denied"]) { c.cancel() }   // say why before hanging up
                        return
                    }
                    if let d = m["device"] as? String, Devices.isValid(d) {
                        authed = true
                        self.reply(c, ["t": "ok", "name": self.config.name])
                    } else {
                        let code = String(format: "%04d", Int.random(in: 0..<10000))
                        if let old = self.pairing?.conn, old !== c { self.reply(old, ["t": "replaced"]) { old.cancel() } }
                        self.pairing = (c, code, 0)
                        let name = self.config.name
                        DispatchQueue.main.async { CodeOverlay.shared.show(code, tv: name) }
                        self.reply(c, ["t": "pair"])
                    }
                case "code":
                    guard var p = self.pairing, p.conn === c else { c.cancel(); return }
                    if secretEquals(m["code"] as? String ?? "", p.code) {
                        self.endPairing(c)
                        authed = true
                        self.reply(c, ["t": "ok", "name": self.config.name, "device": Devices.add()])
                    } else {
                        p.tries += 1
                        self.pairing = p
                        if p.tries >= 5 {   // too many guesses: hang up; a new connection gets a new code
                            self.endPairing(c)
                            self.reply(c, ["t": "locked"]) { c.cancel() }
                            return
                        }
                        self.reply(c, ["t": "pair", "wrong": true])
                    }
                default:
                    c.cancel(); return
                }
                next()
            }
        }
        c.stateUpdateHandler = { [weak self] st in
            if case .cancelled = st { self?.endPairing(c) }
            if case .failed = st { self?.endPairing(c) }
        }
        c.start(queue: queue)
        next()
    }

    func reply(_ c: NWConnection, _ o: [String: Any], then done: (() -> Void)? = nil) {
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        c.send(content: d, contentContext: NWConnection.ContentContext(identifier: "r", metadata: [meta]), isComplete: true,
               completion: .contentProcessed { _ in done?() })
    }
}

// MARK: - network

enum LAN {
    /// This Mac's Bonjour name, e.g. "Lobby-Mac-mini.local" (System Settings > General > Sharing > Local hostname).
    static var hostname: String {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String? ?? Host.current().localizedName ?? "localhost"
        return name + ".local"
    }

    /// The Mac's LAN IPv4 (Wi-Fi or Ethernet), skipping loopback / link-local / VPN-ish interfaces.
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: (rank: Int, ip: String)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (a.ifa_flags & UInt32(IFF_UP)) != 0,
                  (a.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            let rank = name == "en0" ? 0 : 1
            if best == nil || rank < best!.rank { best = (rank, ip) }
        }
        return best?.ip
    }
}

// MARK: - self-update

enum CodeSign {
    /// The team that signed this running app (nil when ad hoc / unsigned).
    static var myTeam: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var stat: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// True if the app at `path` is validly signed by `team` with this app's bundle identifier.
    static func verify(_ path: String, team: String) -> Bool {
        var stat: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &stat) == errSecSuccess, let stat else { return false }
        let id = Bundle.main.bundleIdentifier ?? ""
        var req: SecRequirement?
        let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(stat, flags, req) == errSecSuccess
    }
}

/// Every 15 minutes: if GitHub has a newer release signed by the same team, swap the app in place and
/// exit; launchd restarts it. Anything else (unsigned, other team, other app) is refused.
final class Updater {
    let config: Config
    var timer: Timer?
    init(config: Config) { self.config = config }

    var installed: String? { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }   // nil outside the .app

    func start() {
        guard installed != nil else { return }
        guard CodeSign.myTeam != nil else { log("not signed by a developer team: auto-update off"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        guard let mine = installed, let url = URL(string: "https://github.com/\(releasesRepo)/releases/latest/download/version.txt") else { return }
        var req = URLRequest(url: url); req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let latest = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !latest.isEmpty, latest != mine else { return }
            DispatchQueue.main.async { self.update(to: latest) }
        }.resume()
    }

    func sh(_ script: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh"] + args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func update(to version: String) {
        guard let team = CodeSign.myTeam else { return }
        let app = Bundle.main.bundleURL.path
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wallpad-update-\(randomString(8))").path
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        log("downloading \(version)")
        let zip = "https://github.com/\(releasesRepo)/releases/latest/download/Wallpad.zip"
        guard sh(#"mkdir -p "$2" && curl -fsSL "$1" -o "$2/app.zip" && ditto -x -k "$2/app.zip" "$2/x""#, [zip, tmp]),
              let name = try? FileManager.default.contentsOfDirectory(atPath: tmp + "/x").first(where: { $0.hasSuffix(".app") }) else {
            log("update download failed"); return
        }
        let new = tmp + "/x/" + name
        guard CodeSign.verify(new, team: team) else { log("update refused: not signed by team \(team)"); return }
        guard sh(#"rm -rf "$2.old" && mv "$2" "$2.old" && mv "$1" "$2" && rm -rf "$2.old""#, [new, app]) else {
            log("update install failed"); return
        }
        log("updated to \(version), restarting")
        exit(0)
    }
}

// MARK: - the printable QR card

func writeQRCard(_ c: Config) throws -> URL {
    let filter = CIFilter(name: "CIQRCodeGenerator")!
    filter.setValue(Data(c.qrURL.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    let qr = filter.outputImage!
    let W = 1200.0, H = 1500.0, side = 860.0
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    let scaled = qr.transformed(by: CGAffineTransform(scaleX: side / qr.extent.width, y: side / qr.extent.height))
    let ctx = CIContext()
    if let cg = ctx.createCGImage(scaled, from: scaled.extent) {
        NSGraphicsContext.current!.cgContext.interpolationQuality = .none
        NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: (W - side) / 2, y: 330, width: side, height: side))
    }
    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
        NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 60, y: y, width: W - 120, height: size * 1.4))
    }
    text(c.name, size: 84, weight: .bold, color: .black, y: 1260)
    text("Scan with your phone to control this TV", size: 44, weight: .regular, color: NSColor(white: 0.25, alpha: 1), y: 210)
    text("Your phone needs to be on the office Wi‑Fi", size: 34, weight: .regular, color: NSColor(white: 0.45, alpha: 1), y: 140)
    NSGraphicsContext.restoreGraphicsState()
    try? FileManager.default.createDirectory(at: home.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
    let out = home.appendingPathComponent("Desktop/\(c.name) Wallpad QR.png")
    try rep.representation(using: .png, properties: [:])!.write(to: out)
    return out
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

switch args.first {
case "setup":
    var c = loadConfig() ?? Config(name: Host.current().localizedName ?? "Office TV",
                                   token: randomString(32, "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"))
    if let n = arg("--name") { c.name = n }   // re-running setup keeps the QR secret, so printed codes keep working
    try saveConfig(c)
    print("configured \(c.name): \(c.qrURL.prefix(while: { $0 != "#" }))")
    print("QR card: \(try writeQRCard(c).path)")
case "preview-code":   // renders the TV's pairing card to a PNG (for checking the design)
    let v = CodeOverlay.view("4821", tv: "Lobby TV", size: NSSize(width: 1280, height: 720))
    v.wantsLayer = true; v.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1).cgColor
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arg("--out") ?? "code.png"))
case "qr":
    guard let c = loadConfig() else { print("not set up: run wallpad setup first"); exit(1) }
    print(try writeQRCard(c).path)
default:
    guard let c = loadConfig() else { log("not set up: run wallpad setup"); exit(1) }
    // Moving the pointer and typing need Accessibility access (System Settings > Privacy & Security > Accessibility).
    let trusted = Input.dryRun || AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    if !trusted { log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)") }
    NSApplication.shared.setActivationPolicy(.accessory)   // no Dock icon, but may show the pairing code
    let server = try Server(config: c)
    server.start()
    let updater = Updater(config: c)
    updater.start()
    // keep the Mac awake enough to answer (the display can still sleep)
    let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Wallpad")
    _ = activity
    RunLoop.main.run()
}
