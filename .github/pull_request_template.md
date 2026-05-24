<!--
Thanks for the PR! A few quick checks before you submit.
Delete sections that don't apply.
-->

## What changed and why

<!-- One short paragraph. What problem does this solve? -->

## Type of change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (would cause existing behaviour to change)
- [ ] Build / packaging / docs only (no runtime code change)

## How I tested

<!-- Did you actually run the app and try it? Don't just say "looks good".
     If the change touches RDP/SSH/etc, list the protocols/hosts you tested
     against and the macOS version. -->

- macOS version:
- Tested protocols / scenarios:
- Steps to verify:

## Screenshots

<!-- For UI changes, before/after screenshots are very helpful. -->

## Checklist

- [ ] My commits follow the [Conventional Commits](https://www.conventionalcommits.org/) style used in this repo (`feat:`, `fix:`, `docs:`, `build:`, ...).
- [ ] New source files have the SPDX header (`// SPDX-License-Identifier: GPL-2.0-or-later`).
- [ ] Comments in code are in English.
- [ ] Any new user-visible string goes through `t("Key")` and is added to **both** `App/Resources/en.lproj/Localizable.strings` and `ro.lproj/Localizable.strings`.
- [ ] I ran `xcodegen generate && xcodebuild ... build` locally and the app launches.
- [ ] If this changes the `.dmg`, I rebuilt it with `./build/package.sh` and verified no `/opt/homebrew/` leaks.

## Related issues

<!-- Closes #123 / Refs #456 -->
