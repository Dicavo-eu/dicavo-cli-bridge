# Security policy

The Dicavo CLI Bridge runs AI command-line tools on your Mac and hands them meeting transcripts, so we take reports about it seriously.

## Reporting a vulnerability

Email **support@dicavo.eu** with "Security" in the subject line. Please do not open a public issue for a vulnerability.

Include what you can:

- the bridge version and build (shown at the top of the bridge's menu) and your macOS version
- what an attacker can do, and what they need first (for example, another process running as the same user)
- steps or code that reproduce it

We will confirm that we received your report within five working days and keep you informed until it is resolved. Once a fix has been released, we will credit you in the release notes if you want us to.

## Scope

In scope: the code in this repository and the DMGs published on dicavo.eu, in particular:

- the loopback server and its token check
- how the bridge starts Claude Code, Codex, Antigravity and the local command
- the update check, download and installation

Out of scope: vulnerabilities in the tools themselves (Claude Code, Codex, Antigravity or a local command). Please report those to their vendors.

## Supported versions

Only the latest release receives fixes. The bridge can update itself from the menu.
