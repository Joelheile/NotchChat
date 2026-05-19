# WhatsApp sidecar

Bridges WhatsApp to boring.notch. The macOS app cannot speak the WhatsApp
protocol itself, so this small Go process does, using
[whatsmeow](https://github.com/tulir/whatsmeow). The app launches it
automatically and talks to it over `127.0.0.1`.

## Build

```sh
./build.sh
```

Requires Go (`brew install go`). CGO is enabled because the session store uses
SQLite via `go-sqlite3`, so the Xcode command line tools (clang) must be
installed too. The script builds for the host architecture and writes the
binary to `boringNotch/private/whatsapp-sidecar`, which Xcode then bundles into
`boringNotch.app` automatically.

For an Intel build on Apple Silicon (or vice versa) set `GOARCH` and an
appropriate `CC`, then `lipo` the two binaries together.

## Voice notes

WhatsApp voice notes are Opus-in-Ogg, which `AVAudioPlayer` on macOS cannot
decode. If `ffmpeg` is on `PATH` the sidecar transcodes them to AAC/m4a so they
play in the notch. Without ffmpeg, audio messages still appear but will not play.

```sh
brew install ffmpeg
```

## HTTP API (localhost only)

| Method | Path      | Purpose                                       |
| ------ | --------- | --------------------------------------------- |
| GET    | `/events` | SSE stream: `status`, `qr`, `message` events  |
| GET    | `/status` | `{connected, loggedIn, selfJID}`              |
| POST   | `/send`   | body `{to, text}`                             |
| GET    | `/media`  | `?id=<messageID>` returns cached audio        |
| POST   | `/logout` | unlinks the device and clears cached messages |

## App sandbox

boringNotch ships sandboxed. A sandboxed app can spawn a bundled helper, but
the helper inherits the sandbox and code-signing rules. For a local dev build
(app signed "to run locally") the ad-hoc-signed sidecar launches fine. If it is
killed on launch, either sign it with the same team as the app, or remove
`com.apple.security.app-sandbox` from `boringNotch/boringNotch.entitlements`.
The sidecar writes only inside the app's container Application Support, so file
access stays within the sandbox.

## Unofficial client warning

This bridge uses [whatsmeow](https://github.com/tulir/whatsmeow), an unofficial
WhatsApp library. WhatsApp's Terms of Service only permit official clients.
Linking a device this way carries a real risk of the WhatsApp account being
banned. Use a number you can afford to lose, not a critical primary account.
This project is not affiliated with or endorsed by WhatsApp or Meta.

## Notes

- Session and message cache live in the app's (container-redirected)
  `Application Support/boringNotch/whatsapp`.
- Message history from before the device was linked is not imported; messages
  accumulate from first run onward.
- The whatsmeow API changes often. If `go build` fails on a signature, adjust
  the call in `main.go` to match the version `go mod tidy` resolved.
