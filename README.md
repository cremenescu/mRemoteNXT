# mRemoteNXT

> Romanian: see [README.ro.md](README.ro.md)

Native macOS multi-protocol remote connection client (SSH, RDP, Telnet,
SFTP, HTTP/HTTPS) with direct import of `confCons.xml` files from
**mRemoteNG**.

Written as a native Mac alternative for people who use mRemoteNG on
Windows and don't want to give up the connection tree, encrypted passwords
and the tabs+panels layout.

> Status: **alpha**. Used daily against ~700 real connections, but some
> features are missing and exotic configurations can hit bugs. See
> [Known limitations](#known-limitations).

## Screenshots

![Main view — connection tree with an SSH tab open](examples/screenshots/screenshot-hero.png)

<details>
<summary>More screenshots</summary>

![Empty workspace placeholder when no connection is open](examples/screenshots/screenshot-main.png)

![Settings — Appearance pane (UI font size, terminal theme, row height, toggles)](examples/screenshots/screenshot-settings.png)

</details>

The data shown is the demo file at
[`examples/demo-config.xml`](examples/demo-config.xml) — IANA documentation
ranges, no real hosts.

## Features

- **Direct `confCons.xml` import** (schema 2.6, with mRemoteNG's default passphrase
  or a custom one). Crypto validated byte-exact against real files
  (PBKDF2-HMAC-SHA1 + AES-256-GCM).
- **Connection tree** with folders, attribute inheritance, drag&drop reorder,
  original mRemoteNG icons, guide lines.
- **Panels** — group connections into top-level tabs like on Windows.
- **Search / filter** by name, host, protocol, description.
- **SSH** + **Telnet** embedded in tabs (PTY over system `ssh`/`telnet`
  via SwiftTerm). PuTTY-style copy-on-select + right-click paste.
- **SFTP** in terminal (right-click an SSH connection → "Transfer files").
- **RDP** embedded via **FreeRDP** (GFX/disp/cliprdr channels wired by hand,
  live resize, correct DPI scaling on Retina, Ctrl+Alt+Del via menu).
- **HTTP / HTTPS** embedded in `WKWebView` with auto-fill of username +
  password from the tree (handy for router / iLO / switch web UIs).
- **External Tools** with macros (`%Host% %Username% %Port% %Password%
  %Domain% %Name%`) — executed in a terminal tab.
- **Connection editor** modal in Royal TSX style (categories: General /
  Connection / Credentials / Appearance / Advanced) + a bottom status bar
  with host / user / password click-to-copy.
- **Auto-backup on save** to `backups/confCons-<timestamp>.xml` on every
  write (your original file is never lost).
- **Terminal themes** (Default, Solarized, Dracula, etc.), live-adjustable
  font size, zoom Cmd+/Cmd-.

## Known limitations

- `FullFileEncryption="true"` (whole XML encrypted) — not implemented.
- Schema `ConfVersion > 2.6` — untested.
- `Panel` inheritance across multiple levels — partial.
- RDP: image-clipboard redirect, drive / sound redirect, remote cursor
  visibility (pointer set/new callbacks).
- VNC (planned).
- External applications (`IntApp` nodes) — launching not implemented.
- Quick Connect (URL `ssh://user@host:port`) from CLI.

## System requirements

- macOS 14 (Sonoma) or newer.
- Xcode 16+ (with Metal Toolchain — see [BUILD.md](BUILD.md)).
- Homebrew with `freerdp` (3.x) and `xcodegen`.

## Installation

### Option A: pre-built `.dmg` (recommended)

Download the latest `mRemoteNXT-vX.Y.Z-alpha.dmg` from
[Releases](https://github.com/cremenescu/mRemoteNXT/releases),
open it, drag the app to the Applications shortcut, then open it.

The app is **signed with a Developer ID and notarized by Apple**, so it
opens with no Gatekeeper warning and no `xattr` workaround. No Homebrew
install required — FreeRDP and friends are bundled inside the app.

### Option B: build from source

See [BUILD.md](BUILD.md). Requires Xcode, Homebrew, `freerdp`,
`xcodegen`. Run `./build/package.sh` to produce your own `.dmg`.

## License

**GPL-2.0-or-later**. See [LICENSE](LICENSE).

The bundled icon set is taken from the official
[mRemoteNG](https://github.com/mRemoteNG/mRemoteNG) project (GPL-2.0),
which is why this project is under the same license. The code and the
`confCons.xml` format were re-implemented independently (not a port of
their code) from observation of real files produced by mRemoteNG.

## Credits / dependencies

- [mRemoteNG](https://github.com/mRemoteNG/mRemoteNG) — `confCons.xml`
  format and icon set (GPL-2.0).
- [FreeRDP](https://github.com/FreeRDP/FreeRDP) — RDP client library
  (Apache-2.0).
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal
  emulator (MIT).
- Apple SwiftUI / AppKit / WebKit / CryptoKit / CommonCrypto.

## Impostor repositories

The only official mRemoteNXT repository is
**<https://github.com/cremenescu/mRemoteNXT>**. Releases (`.dmg`) are
published only there.

Any other repository on GitHub using the name "mRemoteNXT" is unaffiliated
and may be malicious. The project is **Swift only** — if a repo claiming to
be mRemoteNXT contains Lua, Python, JavaScript or pre-built executables,
do not clone it and do not run anything from it.

## Disclaimer

This project is not affiliated with, endorsed by, or warranted by the
mRemoteNG team. "mRemoteNG" is used only as a format-compatibility
reference.

## Author

Razvan Cremenescu — <https://github.com/cremenescu>
