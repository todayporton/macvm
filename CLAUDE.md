# macvm

CLI for running macOS GUI tests in one shared headless Tart VM. See `README.md` for usage and `docs/DESIGN.md` for the reasons behind the design. Read the relevant part of `DESIGN.md` before changing behaviour.

## Layout

- `bin/macvm`: VM lifecycle, setup, lock, command dispatch
- `lib/`: `apps.sh`, `gui.sh`, `integrations.sh`, `mcp.sh` (sourced by `bin/macvm`; bash 3.2)
- `helper/*.swift`: the program that runs inside the guest
- `skill/claude/SKILL.md`: the Claude Code skill
- `test/verify.sh`: end-to-end test against the real VM
- `Formula/macvm.rb`: template for the formula in `todayporton/homebrew-tap`

## Develop and verify

The installed `macvm` is the Homebrew build, so source edits do not affect it. Run the checkout instead:

```bash
make                     # builds build/macvm-helper; needed after changing helper/
bin/macvm help
test/verify.sh --stop    # needs the VM; uses the checkout's bin/macvm; add --stop to test shutdown
```

- Run `test/verify.sh --stop` after changing behaviour. It uses the shared VM, so it waits if another session holds the lock.
- Add a check to `test/verify.sh` with each bug fix. Assert from the app's event log or UI state, not from exit codes alone.
- Also try real apps when changing accessibility code. The test app has hidden real-world problems before.
- A problem seen only on a new VM needs a test on a new VM: `tart delete macos-test`, then `macvm setup`. Delete it only when no other session is using it.

## Rules

- Never automate the host's GUI, including while testing macvm.
- macvm must not depend on any AI agent. Agent-specific code stays in `lib/integrations.sh` and `skill/`. Do not read agent environment variables in the core.
- Keep the guest image's login settings alone. Deleting `~/Library/Preferences/ByHost/com.apple.loginwindow.*` makes Setup Assistant take over at every login.
- Do not upgrade `tart-guest-agent` inside the VM: TCC grants name its versioned path.
- Under `set -o pipefail`, write `| grep x >/dev/null`, not `| grep -q x`, because the early exit can fail the pipeline.
- Bash on macOS is 3.2. An empty array under `set -u` needs `${a[@]+"${a[@]}"}`.

## Release

Changes reach `brew upgrade` only after a release. Commit, push, tag and create a release only when asked.

1. Update `VERSION` in `bin/macvm`, then commit and push to `main`.
2. Tag `vX.Y.Z`, push the tag, and run `gh release create`.
3. Get the checksum: `curl -fsSL https://github.com/todayporton/macvm/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`
4. Update `url` and `sha256` in `Formula/macvm.rb` of `todayporton/homebrew-tap`, and push. Run `brew audit --strict todayporton/tap/macvm`.
5. Run `brew update && brew upgrade macvm`, and `macvm integrate claude` if the skill changed. The next `macvm start` updates the helper in the VM.
