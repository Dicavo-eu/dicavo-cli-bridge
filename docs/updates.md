# How the bridge updates itself

Dicavo is distributed through the App Store, but the bridge is not, so the bridge updates itself. The code is in `Sources/BridgeCore/BridgeUpdate*.swift` and `Sources/DicavoBridge/BridgeUpdateController.swift`.

## When it checks

- **Manually:** *Check for updates…* in the menu. Every check reports a result: up to date, update available, or an error.
- **Automatically:** only if you turned it on, at first launch or later in the menu. Automatic checks are off by default. When they are on, every hour and at launch, the bridge checks whether 24 hours have passed since the last update check and performs an update check if they have.

A check is a single HTTPS GET for `https://dicavo.eu/bridge/latest.json` through an ephemeral `URLSession`, with no cookies, cache or credentials. A redirect is followed only to another HTTPS URL on dicavo.eu. The request contains no data about your recordings or your tools. Like any HTTPS request, it reveals your IP address and the app's User-Agent to dicavo.eu.

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
- `url` is not HTTPS on `dicavo.eu`, or carries a user name, password or port other than 443
- `sha256` is not 64 hexadecimal characters
- `build` is not positive, or `version` is empty
- `size` is zero or larger than 50 MB
- `minimumSystemVersion` is not a macOS version such as `14.2`

The bridge does not offer an update that requires a newer version of macOS than yours. The menu says which macOS version it needs.

## Installing

1. **Download** into a private work folder, next to the installed app when it can be replaced there. The file is named `DicavoCLIBridge-<build>.dmg`, never after the URL, and is readable by your user account only. A redirect away from dicavo.eu is not followed, and the download stops as soon as it is larger than the manifest's `size`.
2. The **size** and **SHA-256** of the file must match the manifest.
3. **Attach** the image read-only, with `diskutil image attach`, or with `hdiutil attach` if that fails. The image must contain an app named exactly `Dicavo CLI Bridge.app`, which is copied into the work folder with `ditto`. The image is always detached at the end.
4. **Signature** of the copy: `SecStaticCodeCheckValidity` (strict, all architectures, nested code, revocation enforced) must satisfy two requirements:
   - the designated requirement of the **running** bridge
   - `anchor apple generic and identifier "cz.smartbrains.dicavo.bridge" and certificate leaf[subject.OU] = "H8LTS9AT3K"`
5. **Bundle:** same `CFBundleIdentifier`. `CFBundleVersion` must equal the manifest's `build` and be higher than the running build.
6. **Notarization:** if the running bridge is signed with Developer ID, as every published one is, or passes Gatekeeper, the copy must pass Gatekeeper (`spctl --assess --type execute`). If the assessment fails for any reason, including no network, the update is not installed. A locally signed development build skips this step.
7. **Wait:** new requests from Dicavo are answered with `503 bridge_updating`, and installation waits until the requests already running have finished.
8. **Replace:** steps 4–6 run again on the copy, then `FileManager.replaceItemAt` replaces the installed bundle, and the new version starts once the old one has quit.
9. **Fallback:** if the bridge cannot write to its folder, or runs from a disk image or under App Translocation, it moves the verified image to your Downloads folder and opens it in Finder so you can move the app yourself.

Every tool these steps run (`diskutil`, `hdiutil`, `ditto`, `spctl`) is stopped after 120 seconds. A failure in steps 1–6 or 8 deletes the work folder, replaces nothing and shows the error in the menu with a link to the download page.
