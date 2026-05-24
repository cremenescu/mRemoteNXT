# Contributing to mRemoteNXT

Thanks for your interest! mRemoteNXT is an alpha-stage native macOS
client for `confCons.xml` files from mRemoteNG. Help is welcome.

## Reporting bugs

Open a GitHub issue using the **Bug report** template. The most useful
thing you can include is:

- the macOS version (Apple menu > About This Mac);
- the mRemoteNXT version (Help > About mRemoteNXT);
- whether you launched from the `.dmg` or built from source;
- the exact steps to reproduce;
- the actual vs expected behaviour.

If the bug is a **crash**, attach the crash report from
`~/Library/Logs/DiagnosticReports/mRemoteNXT_*.ips`.

For security issues, do **not** open a public issue. See
[SECURITY.md](SECURITY.md).

## Suggesting a feature

Use the **Feature request** template. Be concrete about the problem
you're trying to solve — that's more useful than just a wish-list item.

## Sending a pull request

1. Build the project locally first — see [BUILD.md](BUILD.md).
2. Keep the change focused: one feature or fix per PR. Easier to review,
   easier to revert if something breaks.
3. Commit messages: use the
   [Conventional Commits](https://www.conventionalcommits.org/) style
   already used in this repo. Examples in `git log`:
   - `feat: add VNC protocol support`
   - `fix: HelpView crash when no LanguageManager in environment`
   - `docs: clarify install steps in README`
   - `build: bundle libssh2 in the .dmg`
4. Follow the existing code conventions:
   - Identifiers in English, comments in English.
   - SPDX license header at the top of every new source file:
     `// SPDX-License-Identifier: GPL-2.0-or-later`
   - 4-space indent, no tabs.
   - User-visible strings must go through `t("Key")` and be added to
     both `App/Resources/en.lproj/Localizable.strings` and the `ro.lproj`
     equivalent.
5. Run the app locally and make sure your change actually works in the
   bundle (not just in unit tests).
6. Open the PR against `main` with a short description of what changed
   and why.

I review PRs personally and won't always be fast. If a PR sits for more
than a couple of weeks, ping me on the PR or by email
(`razvan@cremenescu.ro`).

## License

By contributing, you agree that your contribution is released under the
project's license, [GPL-2.0-or-later](LICENSE).
