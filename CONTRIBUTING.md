# Contributing

- License: Apache-2.0. Contributions use **DCO** — every commit needs `Signed-off-by:` (`git commit -s`). No CLA required.
- Trademark: the name and icon are protected by TRADEMARK.md; forks may freely reuse the code but may not publish under the original name.
- Report security issues privately per SECURITY.md.
- Conduct: CODE_OF_CONDUCT.md applies to every project space.
- Definition of done for any task: Implementation + Tests + Documentation + Diagnostics (where applicable) + no known security regression.
- Undocumented APIs are allowed only inside `ThresholdSystem`, and must ship with a Fake and a spike.
- **Roadmap**: the maintainer sets project direction and decides what ships toward v1.0. Bug fixes and small, well-scoped improvements are welcome as PRs directly. For anything larger — a new feature, a new supported-device class, a change to an accepted ADR — please open an issue first so the direction can be discussed before you invest the work.

## Development

**One worktree per branch.** Keep the main checkout on `main`; open feature branches under `../threshold-wt-<name>`:

```bash
git worktree add ../threshold-wt-<name> -b feat/<name> main
```

This keeps parallel work from clobbering each other's uncommitted files, and prevents editing on the wrong branch by accident. Check `git status --short --branch` and your current directory before you start editing.

### Run before every commit

```bash
scripts/check-boundaries.sh
swift build
swift test
scripts/make-app-bundle.sh debug     # when the App target, Package.swift, or the bundle script changed
```

CI (`.github/workflows/ci.yml`) runs the same set, plus `swift build --package-path Tools/rssi-record`. Any non-zero exit counts as a failure.

### Fixture privacy rules

Files under `Tests/Fixtures/BLE/` must never contain a UUID, a MAC address, an advertised name, or a wall-clock timestamp. `scripts/check-boundaries.sh` checks for this, but it isn't the only line of defense — `Tools/rssi-record` is designed so identifiers and names can never reach its write path in the first place. Real-device fixtures are always produced through that tool; never hand-paste raw scan output.

The same script also checks five other boundaries: Domain does not import any other target, no private frameworks, no credential handling or synthesized keystrokes, undocumented signals appear only in `ThresholdSystem`, and Domain never reads a clock.

### Spike document rules

**No result before the experiment runs.** A spike's status stays `NOT RUN` until there's an actual experiment log — never write the expected conclusion first.

When there are measurements but the success criteria are not fully verified, the status is `PARTIAL`, and the document must include both:

- `## Evidence` — the real environment, tooling, runs and numbers, with devices always referred to by alias;
- an explicit "not yet measured" list, mapped item by item to that document's own experiment sections.

`GO` / `CONDITIONAL GO` / `NO-GO` may only be written once the success criteria are fully verified, with evidence attached. Raw data stays under `Tools/spikes/out/` (gitignored); no identifier, device name, or hostname may appear in the document itself.

### Commit trailers

Every commit needs a DCO sign-off:

```bash
git commit -s
```

This adds `Signed-off-by: Name <email>`. AI-assisted commits additionally carry:

```text
Co-Authored-By: <model name> <noreply@anthropic.com>
Claude-Session: <session URL>
```
