# examples/

Sample data for trying out mRemoteNXT without exposing any real
credentials.

## `demo-config.xml`

A ready-to-open `confCons.xml` (mRemoteNG 2.6 schema) with:

- **4 folders** — Lab, Servers, Workstations, Cloud — plus one
  top-level connection.
- **15 connections** covering every protocol the app supports
  today: SSH, RDP, Telnet, HTTPS, plus `IntApp`-shaped entries.
- **A variety of icons** from the bundled mRemoteNG set (Router,
  Switch, Firewall, Web Server, Database, ESX, Workstation, Linux,
  WiFi, Backup, …).
- **Encrypted passwords** using the default mRemoteNG passphrase
  `mR3m` (PBKDF2-HMAC-SHA1 1000 iterations + AES-256-GCM, AAD = salt).
  All passwords decrypt cleanly inside the app.

All hostnames use IANA documentation ranges (`192.0.2.0/24`,
`198.51.100.0/24`, `203.0.113.0/24`) and the `.example` TLD, so
nothing in this file points to a real machine. Safe to share, embed
in screenshots, ship on the website.

To try it: open the app, **File > Open confCons.xml...** (`Cmd+O`)
and pick this file. No master-password prompt — it uses the default.

## `seed-source/main.swift`

The Swift program that produced `demo-config.xml`. Useful if you
want to add or change entries and regenerate from a single source
of truth.

It uses the same `MRNGCore` library the app itself uses, so the
output is byte-identical to what the app would write on Save.

### Regenerating

The generator is **not** wired into `Package.swift` (it's not part
of the public build). To run it:

```bash
# 1. Temporarily re-add it as a target. In Package.swift add:
#      .executable(name: "seeddemo", targets: ["seeddemo"])  to products
#      .executableTarget(name: "seeddemo", dependencies: ["MRNGCore"]) to targets
# 2. Symlink the source so SPM finds it:
ln -s ../examples/seed-source Sources/seeddemo
# 3. Build + run:
swift run -c release seeddemo > examples/demo-config.xml
# 4. Revert Package.swift and remove the symlink.
```

Or just inline the same logic in a one-off `mrngprobe`-style script.
