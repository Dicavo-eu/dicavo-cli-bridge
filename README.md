# Dicavo CLI Bridge

Dicavo CLI Bridge is an optional menu-bar helper for [Dicavo](https://dicavo.eu), a meeting recorder for the Mac. Dicavo runs in the App Store sandbox, and a sandboxed app cannot start other programs. The bridge is a separate app that is not sandboxed. It runs the AI command-line tool you already have installed and signed in to: Claude Code, Codex, Antigravity or one local command you set up yourself. With Claude Code, Codex or Antigravity, Dicavo can write meeting summaries with your existing subscription, without an API key.

Every transcript Dicavo sends to one of these tools goes through the bridge. This repository holds the bridge's complete source code, so you can check what it does.

## What the bridge does

- Listens for Dicavo on `127.0.0.1` only (port 48123 when free). It accepts only requests that carry a bearer token. The bridge generates a new token every time it starts.
- Writes the port and token to `bridge.json` in the App Group container that it shares with Dicavo. This is how Dicavo finds a running bridge.
- For each request, starts one tool directly, without a shell, with the prompt on standard input, and returns the tool's Markdown answer to Dicavo:
  - **Claude Code** runs with `--tools ""`, no MCP servers (`--strict-mcp-config` and an empty `--mcp-config`), no user settings (`--setting-sources ""`), no slash commands and no session persistence.
  - **Codex** runs `exec --ephemeral --sandbox read-only --ignore-user-config`, with its shell, apps, plugins, browser and computer use, hooks, image tools and web search turned off.
  - **Antigravity** runs with slash commands off and a hook that denies every tool call except the one that returns the answer.
  - **Local command** is a single program with its arguments that you set up in the bridge's own window (for example `llm`, or `ollama` with `run` and a model name). You give it an absolute path, one argument per line and a timeout of at most 600 seconds. The setting stays in the bridge's own preferences, never in the shared container, so Dicavo cannot change which program the bridge runs.
- Stops the tool when Dicavo cancels the request or gives up waiting, and when the bridge quits.

## What the bridge does not do

- It does not listen on any network interface other than loopback, and it has no setting to enable listening on another interface.
- The bridge itself has no account, no analytics and no telemetry.
- It does not keep transcripts. Files the bridge writes for one run go into a private temporary folder that it deletes when the run ends. What a tool and its provider keep is up to that tool and provider.
- It does not read Dicavo's recordings or library. It sees only what Dicavo sends in a request.

## What leaves your Mac, and where it goes

| When | What | To |
|---|---|---|
| Dicavo asks for an analysis | The prompt Dicavo built, including the transcript | The tool you picked. Claude Code, Codex and Antigravity send it to their respective providers (Anthropic, OpenAI and Google) under your account and the respective provider's terms. A local command sends it wherever that command sends it. |
| You check for updates or have turned on automatic checks (off by default) | An HTTPS GET for `https://dicavo.eu/bridge/latest.json`, with no cookies or credentials | dicavo.eu |
| You install an update | A download of the DMG named in that manifest. The download URL must use HTTPS and be on dicavo.eu. | dicavo.eu |

Dicavo asks for your consent before it sends a transcript to the bridge, the same way it does for a cloud API.

## Updates

The bridge installs an update only if all of these checks pass on the downloaded copy:

- size and SHA-256 match the manifest
- the code signature satisfies the running bridge's designated requirement and Team ID `H8LTS9AT3K`
- the build number is higher than that of the running bridge
- if the running copy is notarized, the new copy passes Gatekeeper too

Details are in [docs/updates.md](docs/updates.md).

## Releases

From version 2.2 on, each DMG published on [dicavo.eu](https://dicavo.eu/en/bridge.html) is built by `scripts/make-dmg.sh --distribution` from a commit in this repository, signed with Developer ID and notarized by Apple. Each release lists the commit and the SHA-256 of the DMG. Earlier releases were built from the private Dicavo repository.

**Builds are not reproducible.** The signature, its timestamp and the notarization ticket change on every build, so a DMG you build yourself from the same commit will not match the published file byte for byte. The commit tells you which source the release was built from. The SHA-256 lets you check that your download matches the file listed here.

| Version | Build | Source commit | DMG SHA-256 |
|---|---|---|---|
| 2.1.1 | 23 | `0fe4c8a` in the private Dicavo repository, before this repository existed | `7843dffb9e4ff841b73d23399c74c7281239dab90acdfc7961b851256f53dd8a` |

## Building

Requirements: macOS 14.2 or later and Xcode 26 or later.

Run the tests (no signing needed):

```sh
swift test
```

Build the app without signing:

```sh
xcodebuild -project DicavoBridge.xcodeproj -scheme DicavoBridge \
  -configuration Release -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Build a signed DMG with your own Apple Development certificate:

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# fill in your certificate's SHA-1 and your team ID
scripts/make-dmg.sh --ref HEAD
```

`Config/Signing.local.xcconfig` is ignored by Git. `scripts/make-dmg.sh --distribution --notary-profile <name>` produces a DMG signed with Developer ID and notarized by Apple, and reads the identity from your login Keychain.

A bridge you sign with your own team cannot talk to Dicavo from the App Store. The App Group `H8LTS9AT3K.cz.smartbrains.dicavo` and the update check belong to the Team ID that signs Dicavo, and macOS shares the group only with apps from that team. You can still run your build, read the code and run the tests.

## Layout

- `Sources/BridgeCore`: the loopback server, the HTTP parser, the request handler, the command runner and the updater. Foundation only. Dicavo compiles the same source files to talk to the bridge.
- `Sources/DicavoBridge`: the menu-bar app.
- `Tests/BridgeCoreTests`: unit tests, including tests that run real processes.

## Security

See [SECURITY.md](SECURITY.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The license does not grant rights to the Dicavo name or icons.
