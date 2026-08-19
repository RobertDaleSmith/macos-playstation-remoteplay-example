import SwiftUI

/// Deliberately plain. Everything here is a thin skin over `RemotePlayClient`; the interesting
/// code is in Input/ and Protocol/.
struct ContentView: View {
    @ObservedObject var client: RemotePlayClient
    @ObservedObject var source: ExampleInputSource
    @ObservedObject private var gamepad: RPGamepadSource
    init(client: RemotePlayClient, source: ExampleInputSource) {
        self.client = client
        self.source = source
        self.gamepad = client.gamepad
    }

    @State private var redirectURL = ""
    @State private var pin = ""
    @State private var pinTarget: RPHostStatus?

    /// Consoles that answered discovery but have not been linked yet.
    private var unlinked: [RPHostStatus] {
        client.discovered.filter { status in
            !client.hosts.contains { $0.hostId == status.hostId }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = client.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                signIn
                Divider()
                consoles
                Divider()
                stream
                Divider()
                inputDemo
                Divider()
                physicalPad
            }
            .padding(20)
        }
    }

    // MARK: - 1. Sign in

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("1 · PlayStation Network").font(.headline)
            if let account = client.account {
                Label("Signed in as \(account.onlineId)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text(
                    "Sign in, then paste the URL of the blank page you land on. It carries the authorization code."
                )
                .font(.caption).foregroundStyle(.secondary)
                Link("Open PlayStation sign-in", destination: client.signInURL)
                HStack {
                    TextField("https://remoteplay.dl.playstation.net/…?code=…", text: $redirectURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Use") {
                        Task { await client.completeSignIn(redirectURL: redirectURL) }
                    }
                    .disabled(redirectURL.isEmpty)
                }
            }
        }
    }

    // MARK: - 2 & 3. Find and link a console

    private var consoles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("2 · Consoles").font(.headline)
                Spacer()
                Button("Search") { Task { await client.search() } }
            }
            if client.hosts.isEmpty && client.discovered.isEmpty {
                Text("Search finds consoles on this network over UDP broadcast.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(client.hosts, id: \.hostId) { host in
                HStack {
                    Label(host.name, systemImage: "link.circle.fill").foregroundStyle(.green)
                    Spacer()
                    switch client.state {
                    case .connected(let name) where name == host.name:
                        Button("Disconnect") { client.disconnect() }
                    case .connecting(let name) where name == host.name:
                        ProgressView().controlSize(.small)
                    default:
                        Button("Connect") { Task { await client.connect(to: host) } }
                    }
                }
            }
            ForEach(unlinked, id: \.hostId) { status in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(
                            "\(status.hostName) — not linked",
                            systemImage: status.isOn ? "power.circle" : "moon.zzz")
                        Spacer()
                        Button("Link…") { pinTarget = status; pin = "" }
                    }
                    if pinTarget?.hostId == status.hostId {
                        Text("Console → Settings → Remote Play → Link Device, then enter the 8 digits.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("12345678", text: $pin).textFieldStyle(.roundedBorder)
                            Button("Link") {
                                Task {
                                    await client.register(status, pin: pin)
                                    pinTarget = nil
                                }
                            }
                            .disabled(pin.count != 8 || client.account == nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Picture and sound

    private var stream: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3 · Picture and sound").font(.headline)
            Text(
                "Optional. The console keeps showing the game on its TV either way — this only asks for a copy of the stream."
            )
            .font(.caption).foregroundStyle(.secondary)
            Toggle("Show video", isOn: $client.showVideo)
            Toggle("Play audio", isOn: $client.playAudio).disabled(!client.showVideo)
            Picker("Quality", selection: $client.quality) {
                ForEach(RemotePlayClient.Quality.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Agreed when the session starts, so a change applies from the next connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - The input layer

    private var inputDemo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("4 · Your input source").font(.headline)
            Text(
                "ExampleInputSource stands in for your device. It implements two methods and calls press/release/setStick — it knows nothing about the protocol."
            )
            .font(.caption).foregroundStyle(.secondary)

            Label(
                source.isConnected ? "Source has a live controller" : "Waiting for a session",
                systemImage: source.isConnected ? "dot.radiowaves.left.and.right" : "zzz"
            )
            .foregroundStyle(source.isConnected ? .green : .secondary)

            HStack {
                Button("Tap ✕") { source.tap(.cross) }
                Button("Tap ○") { source.tap(.circle) }
                Button("Tap PS") { source.tap(.ps) }
            }
            .disabled(!source.isConnected)

            HStack {
                holdButton("Hold ✕", .cross)
                holdButton("Hold R2", .r2)
                holdButton("Hold ▲", .up)
            }
            .disabled(!source.isConnected)

            Toggle("Sweep the left stick in a circle", isOn: $source.isSweeping)
                .disabled(!source.isConnected)

            if !source.held.isEmpty {
                Text("Held: \(source.held.sorted().joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The other input source

    private var physicalPad: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("5 · Physical controller").font(.headline)
            Text(
                "A second RemotePlayInputSource, working the same way yours does. Sources merge, so this and your device can both be live without cancelling each other."
            )
            .font(.caption).foregroundStyle(.secondary)

            if let name = gamepad.connectedName {
                Label(name, systemImage: "gamecontroller.fill").foregroundStyle(.green)
                Text(
                    gamepad.usingRawHID
                        ? "Read as raw HID, which is the only way to get the PS button and the touchpad."
                        : "Read through GameController. The PS button is reserved by macOS on this path."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("No controller attached", systemImage: "gamecontroller")
                    .foregroundStyle(.secondary)
                Text("DualSense, DualSense Edge and DualShock 4 are read directly; anything else GameController recognises works too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Press on mouse-down and release on mouse-up, which is what a sustained hold requires.
    private func holdButton(_ title: String, _ button: RPTakion.Button) -> some View {
        Text(title)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                source.held.contains(title) ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !source.held.contains(title) else { return }
                        source.hold(button, named: title)
                    }
                    .onEnded { _ in source.release(button, named: title) }
            )
    }
}
