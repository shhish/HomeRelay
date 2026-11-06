# HomeRelay agent notes

This repository is public. Never commit personal values: names, emails, home IPs or host names, signing team IDs, tokens. Put machine-specific settings in `Config/Local.xcconfig` or environment variables; both stay out of git. If `AGENTS.local.md` exists, read it too: it holds the owner's local notes.

- `docs/API.md` is the contract for clients. Keep it in sync with `Packages/HomeRelayCore` and don't rename wire fields casually.
- `docs/DESIGN.md` records what's in and out of scope.
- Run `cd Packages/HomeRelayCore && swift test` after changes. `scripts/smoke.py` checks a running instance; only use `--write` on an accessory that's fine to toggle.
- Never print, log or commit token values.
- Publishing: this repo is mirrored to GitHub by CI after every push to `main` and every `v*` tag, so anything that reaches `main` is public at once. Never push to GitHub directly.
