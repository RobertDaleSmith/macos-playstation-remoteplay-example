# PlayStation Remote Play on macOS — a worked example

A complete, dependency-light implementation of Sony's Remote Play protocol in Swift: console
discovery, account linking, the crypto handshake, the Takion transport, controller input, and
H.264 video with Opus audio decoded through the system frameworks.

It exists to be **taken apart and reused**. The protocol work is the same for everybody; what
differs between one product and the next is only *what decides to press the button*. That seam is
a single protocol, [`RemotePlayInputSource`](Sources/PSRemotePlayExample/Input/RemotePlayInput.swift).

## The part you replace

```swift
final class MyDeviceSource: RemotePlayInputSource {
    private weak var input: RemotePlayControllerInput?

    func remotePlayDidConnect(_ input: RemotePlayControllerInput) { self.input = input }
    func remotePlayDidDisconnect() { self.input = nil }

    // Called from your own device's callback, on whatever thread it arrives on.
    func deviceDidReport(_ reading: MyReading) {
        input?.setStick(.left, x: reading.x, y: reading.y)
        if reading.selected { input?.press(.cross) } else { input?.release(.cross) }
    }
}
```

Register it and you are done:

```swift
let client = RemotePlayClient()
client.addInputSource(MyDeviceSource())
```

Your source never sees a socket, a cipher, or a packet. It holds a `RemotePlayControllerInput`
and calls `press`, `release`, `setStick`, `setTrigger`, `releaseAll`. Every call is thread-safe.

Sources **merge** rather than override: a button is held while *any* source holds it, and a stick
follows whichever is pushed furthest from centre. So your device, a physical DualSense, and the
keyboard can all be live at once without cancelling each other. That matters for accessibility
work: someone can be assisted on a pad without fighting the device for control.

### Physical controllers

`RPGamepadSource` is a second real implementation of the same protocol — read it alongside yours.
It passes through:

| Controller | Path |
|---|---|
| DualSense, DualSense Edge | Raw HID (`054C:0CE6`, `054C:0DF2`) |
| DualShock 4, both revisions | Raw HID (`054C:09CC`, `054C:05C4`) |
| Anything else GameController recognises (Xbox, MFi) | GameController framework |

Sony pads are read as **raw HID** rather than through GameController, because that is the only way
to get the **PS button** — macOS reserves it on the framework path — and the **touchpad**, which is
forwarded as real touch points with the right coordinate space for each model (the DS4 and
DualSense touchpads are different sizes, and sending one console the other's coordinates puts the
cursor in the wrong place). Triggers are analog on both. If HID is unavailable the source falls
back to GameController automatically, losing only the PS button and touchpad.

### Two things worth getting right

**Hold, don't tap.** `press` and `release` are separate on purpose. Firing a tap on every event
makes a charged attack, a held direction, or a drive button impossible. Hold the button for as
long as your user's intent lasts.

**Write continuous input as fast as you sample it.** Stick positions are coalesced to 60Hz inside
the controller, so there is no need to rate-limit before calling `setStick`.

## Running it

```sh
make run
```

This builds a real `.app` bundle, which matters: an unbundled binary cannot be granted **Local
Network** permission, and without that the console is never discovered. macOS will prompt on first
launch — if discovery finds nothing, check System Settings → Privacy & Security → Local Network.

Then, in the app:

1. **Sign in** to PSN and paste the URL of the blank page you land on — it carries the auth code.
2. **Search** for consoles on the LAN.
3. **Link** a console once, using the 8-digit PIN from Settings → Remote Play → Link Device.
4. **Connect**. Optionally turn on video and audio.

Steps 1–3 happen once per console; everyday use is only step 4. Credentials go to the keychain,
because a registration key grants control of the console to anyone on its LAN.

## Layout

| Path | What it is |
|---|---|
| `Input/RemotePlayInput.swift` | **The seam.** The protocol you implement. |
| `Input/ExampleInputSource.swift` | A stand-in for your device, driven by the demo's buttons. |
| `Input/RPGamepadSource.swift` | A real second source: any GameController-compatible pad. |
| `Input/RPDualSenseHID.swift` | Raw HID for Sony pads, the only way to read the PS button. |
| `Input/RPController.swift` | The virtual DualShock. Merges sources, coalesces sticks. |
| `Protocol/` | Discovery, OAuth, registration, crypto, session, Takion transport. |
| `Media/` | Takion A/V depacketisation, FEC, H.264 via VideoToolbox, Opus via AVFoundation. |
| `UI/RemotePlayVideoWindow.swift` | Optional video window, with keyboard-to-controller mapping. |
| `RemotePlayClient.swift` | Ties it together. ~300 lines, and the one file to read first. |

Video and audio are **optional and additive**. The console keeps showing the game on its TV
either way — asking for the stream changes nothing about what the console does.

## Notes from the implementation

A few things cost real time to discover, and are commented where they live:

- **Audio must be decoded through `AVAudioConverter`, not `AudioConverterFillComplexBuffer`.**
  Driving the C API by hand accepts every packet and reports success while emitting packet-loss
  concealment — a flat -50dB signal that correlates with the real audio at 0.1%. Nothing errors.
  `AVAudioCompressedBuffer` carries the packet framing the codec needs.
- **Video frames must be marked as sync samples.** Unmarked, every sample looks like a keyframe,
  prediction is applied against the wrong reference, and the picture smears instead of resolving.
- **A/V arrives on a different key** from the one used for control messages (index 3, not 2).
- **Audio latency needs a cap.** A player node plays what it is given, in order, forever. A network
  stall queues a burst, and that latency is then permanent. Video escapes this by displaying
  immediately; audio has to be told to drop.
- **Local Network permission is tied to the app's signature**, so a rebuild can silently invalidate
  it. If discovery stops working after a rebuild, toggle the permission off and on.

## License

**AGPL-3.0** — see [LICENSE](LICENSE).

Not a choice, an inheritance. The protocol was worked out by chiaki and chiaki-ng, both AGPL-3.0,
and pyremoteplay, GPL-3.0. This implementation follows their findings and carries their key tables
verbatim, so it is a derivative work and takes the strictest of their terms. A permissive licence
here would be a claim nobody has the standing to make.

What that means in practice: read it, learn the protocol from it, fork it. If you ship it — or
something built from it — the source goes with it under the same terms. If you need this inside a
closed product, the honest route is a clean-room reimplementation from a written spec, by someone
who has not read this code.

## Credit and status

The protocol was reverse-engineered by the [chiaki](https://git.sr.ht/~thestr4ng3r/chiaki)
(AGPL-3.0), [chiaki-ng](https://streetpea.github.io/chiaki-ng/) (AGPL-3.0) and
[pyremoteplay](https://github.com/ktnrg45/pyremoteplay) (GPL-3.0) projects. Every hard-won detail
here came from them. This is a Swift implementation written against their work, and the static key
tables in `RPKeys.swift` are theirs unchanged. Not affiliated with or endorsed by Sony.

Tested against a PS5. The PS4 paths are implemented and follow the same references, but have not
been exercised on hardware.
