# CLAUDE.md

## Build

The shipping app is `/Applications/NotchChat.app`; a build must end up
installed there, not left in the Xcode derived-data folder.

Build order:

1. Build the WhatsApp sidecar with `whatsapp-sidecar/build.sh`. It is staged
   into the app bundle automatically.
2. Build the `boringNotch` scheme with Xcode.
3. Quit the running app, replace `/Applications/NotchChat.app` with the fresh
   `boringNotch.app` product, and ad-hoc codesign it.

The Xcode scheme is `boringNotch` and the product bundle is `boringNotch.app`;
it is renamed to `NotchChat.app` when installed in `/Applications`.
