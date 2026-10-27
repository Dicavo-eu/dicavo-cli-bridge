# How the bridge updates itself

Dicavo is distributed through the App Store, but the bridge is not, so the bridge updates itself. The code is in `Sources/BridgeCore/BridgeUpdate*.swift` and `Sources/DicavoBridge/BridgeUpdateController.swift`.

## When it checks

- **Manually:** *Check for updates…* in the menu. Every check reports a result: up to date, update available, or an error.
- **Automatically:** only if you turned it on, at first launch or later in the menu. Automatic checks are off by default. When they are on, the bridge checks at launch and then once every 24 hours.

A check is a single HTTPS GET for `https://dicavo.eu/bridge/latest.json` through an ephemeral `URLSession`, with no cookies, cache or credentials. The request contains no data about your recordings or your tools. Like any HTTPS request, it reveals your IP address and the app's User-Agent to dicavo.eu.

## The manifest

```json
{
  "schemaVersion": 1,
  "version": "2.1.1",
  "build": 23,
  "minimumSystemVersion": "14.2",
  "url": "https://dicavo.eu/downloads/DicavoCLIBridge-2.1.1-0fe4c8a.dmg",
  "sha256": "7843dffb9e4ff841b73d23399c74c7281239dab90acdfc7961b851256f53dd8a",
  "size": 1169790,
  "releaseNotesURL": "https://dicavo.eu/en/bridge.html#updates"
}
```

The bridge refuses a manifest if any of these is true:

- it is larger than 64 KB
- `schemaVersion` is not 1
- `url` is not HTTPS on `dicavo.eu`
- `sha256` is not 64 hexadecimal characters
- `build` is not positive
- `size` is zero or larger than 50 MB

The bridge does not offer an update that requires a newer version of macOS than yours. The menu says which macOS version it needs.

## Installing

1. **Download** into a private temporary folder. The size must match the manifest.
2. The **SHA-256** of the file must match the manifest.
3. **Attach** the image read-only, with `diskutil image attach`, or with `hdiutil attach` if that fails. The image is always detached at the end.
4. The image must contain an app named exactly `Dicavo CLI Bridge.app`.
5. **Signature:** `SecStaticCodeCheckValidity` (strict, all architectures, nested code) must satisfy two requirements:
   - the designated requirement of the **running** bridge
   - `anchor apple generic and identifier "cz.smartbrains.dicavo.bridge" and certificate leaf[subject.OU] = "H8LTS9AT3K"`
6. **Bundle:** same `CFBundleIdentifier`. `CFBundleVersion` must equal the manifest's `build` and be higher than the running build.
7. **Notarization:** if the running bridge passes Gatekeeper (`spctl --assess --type execute`), the new one must pass too. So a bridge that passes Gatekeeper does not install an update that Gatekeeper rejects.
8. **Wait:** while the bridge is answering a request from Dicavo, installation waits until that request finishes.
9. **Replace:** copy with `ditto` to the same volume and verify the signature of the copy again. Then `FileManager.replaceItemAt` replaces the installed bundle and the new version starts once the old one has quit.
10. **Fallback:** if the bridge cannot write to its folder, or runs from a disk image or under App Translocation, it opens the verified image in Finder so you can move the app yourself.

A failure in steps 1–7 deletes the download, replaces nothing and shows the error in the menu with a link to the download page.
