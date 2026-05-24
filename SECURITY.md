# Security policy

## Reporting a vulnerability

mRemoteNXT handles SSH / RDP / HTTP credentials and decrypts password
fields stored in `confCons.xml`. If you find a vulnerability — anything
that leaks credentials, bypasses authentication, allows code execution,
or weakens the crypto round-trip — **please do not open a public issue**.

Instead, email me directly:

**razvan@cremenescu.ro**

Use the subject line `[mRemoteNXT security]`. If you want to use PGP,
ask in the first message and I'll send a key.

I'll acknowledge within a few days, work on a fix, and credit you in the
release notes unless you prefer to stay anonymous.

## Scope

In scope:

- The mRemoteNXT app itself (Swift / Objective-C / C source under `App/`
  and `Sources/`).
- The crypto and parser in `MRNGCore` (PBKDF2-HMAC-SHA1 + AES-256-GCM,
  `confCons.xml` round-trip).
- The bundled `.dmg` (anything that could be exploited via the install
  flow, install_name_tool fixups, etc.).
- Bundled dependencies that affect mRemoteNXT specifically. For
  upstream issues, please also report directly to the maintainers
  ([FreeRDP](https://github.com/FreeRDP/FreeRDP/security),
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)).

Out of scope:

- The fact that ad-hoc signing triggers a Gatekeeper warning — that is
  intentional until I get an Apple Developer ID.
- Social-engineering or local-attack scenarios that already assume the
  attacker has full access to the machine.

## Supported versions

This is alpha software. Only the latest release receives fixes. Older
tags are not patched.

| Version       | Supported |
|---------------|-----------|
| latest alpha  | yes       |
| anything else | no        |
