# CLAUDE.md

## Build

The shipping app is `/Applications/NotchChat.app`. After building, the product
must end up there, not left in the Xcode derived-data folder.

Build procedure:

```sh
# 1. Build the WhatsApp sidecar (staged into the app bundle automatically)
cd whatsapp-sidecar && bash build.sh && cd ..

# 2. Build the app
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch \
  -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# 3. Replace the installed app with the fresh build
osascript -e 'quit app "NotchChat"' 2>/dev/null || true
rm -rf /Applications/NotchChat.app
cp -R build/Build/Products/Debug/boringNotch.app /Applications/NotchChat.app
codesign --force --deep --sign - /Applications/NotchChat.app
```

The Xcode scheme is `boringNotch`; the product bundle is `boringNotch.app`.
It is renamed to `NotchChat.app` when installed in `/Applications`.
