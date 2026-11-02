# macvm

Run GUI tests of native macOS apps in a shared, headless [Tart](https://tart.run) VM. Humans and AI agents can click through an app while you keep using your Mac: the host's cursor, keyboard and window focus are never touched.

```bash
macvm start
macvm install ./build/MyApp.app
macvm launch com.example.MyApp
macvm ax press com.example.MyApp --role AXButton --title Save
macvm screenshot
macvm quit com.example.MyApp
macvm stop
```

macvm is a plain CLI and does not depend on any AI agent. Claude Code support is a separate, optional integration.

## Requirements

- Apple Silicon Mac, macOS 15 or later (older versions also need `jq`)
- Xcode or Command Line Tools to build the helper
- About 26 GB of download, and up to about 50 GB of disk for the VM

Tart is free for personal computers under its [Fair Source license](https://tart.run/licensing/); check the terms for organisational use. `macvm setup` installs it if it is missing.

## Install

```bash
brew install poTKC/tap/macvm
macvm setup
```

Or from source, into `~/.local` (set `PREFIX=...` for elsewhere):

```bash
git clone https://github.com/poTKC/macvm.git && cd macvm
./install.sh
macvm setup
```

`Formula/macvm.rb` is the template for the formula in [poTKC/homebrew-tap](https://github.com/poTKC/homebrew-tap).

`macvm setup` is safe to re-run, and does the following:

1. Installs Tart if it is missing, into `~/.local/opt/tart`. The release must match its published checksum, be signed by the expected team, and pass Apple's notarization check.
2. Creates the VM `macos-test` from `macos-tahoe-base`, or reuses it if it exists. Other VMs are left alone.
3. Creates a dedicated SSH key, authorizes it, and disables SSH password login in the guest.
4. Copies the guest helper in, turns off guest sleep and indexing, and checks TCC permissions.
5. If `~/.claude` exists, runs `macvm integrate claude`. Skip this with `--no-integrations`.

## Update and uninstall

| Task | Command |
| --- | --- |
| Update | `git pull && ./install.sh`, or `brew upgrade macvm`. The next `macvm start` updates the helper in the VM; run `macvm integrate claude` to update the skill. |
| Remove user data and the integration, keep the VM | `macvm teardown --yes` |
| Also delete the VM | `macvm teardown --delete-vm --yes` |
| Remove the program | `make uninstall`, or `brew uninstall macvm` |
| Remove Tart, if macvm installed it | `rm -rf ~/.local/opt/tart ~/.local/bin/tart` |
| Remove the cached base image | `tart delete ghcr.io/cirruslabs/macos-tahoe-base:latest` |

Teardown only removes what macvm owns: its state directory, its skill (identified by a marker) and its delimited block in `CLAUDE.md`. Nothing is written to `~/.ssh`.

## Commands

Run `macvm help` for the full list. ID is the bundle id, or the file name for an executable with no bundle, such as `swift build` output. Wherever a command takes a bundle id, it accepts that file name too.

| Group | Commands |
| --- | --- |
| VM | `setup` `start` `stop` `status` `ssh` `view` `teardown` `integrate` |
| Apps | `install` `launch` `quit` `app-status` `apps` `frontmost` |
| UI elements | `ui elements` `ui tree` `ui text` `ui find` `ui click` `ui type` `ui focus` `ui menu` `ui wait` |
| Coordinates | `click` `doubleclick` `rightclick` `move` `drag` `scroll` `key` `type` |
| Windows | `windows` `activate` `screen` |
| Waiting | `wait` `wait-window` |
| Output | `screenshot` `logs` `crashes` `collect` `clean` |
| Lock | `lock` `unlock` `lock-status` |
| Agents | `mcp` |

Exit codes: `3` app or element not found, `4` missing TCC permission in the VM, `5` helper refused to run outside a VM, `6` element disabled, `7` element covered or unreachable, `8` selector ambiguous, `75` lock held by another session.

## UI elements first, coordinates when needed

```bash
macvm ui elements                       # controls in reach, as one JSON object per line
macvm ui click --label 保存             # a real mouse click at the element's centre
macvm ui type --id searchField "hello"  # focuses, types real keys, prints the new value
macvm ui menu File "Save As…"
macvm ui wait --id status --value done
macvm click 300 200                     # for custom-drawn views with no accessible element
```

`ui click` refuses a disabled, covered or ambiguous target instead of clicking something a user could not. Coordinates and screenshots remain for what accessibility cannot reach or show. On Calculator, listing the controls took 2.6 KB against 1.8 MB for a screenshot.

## AI agents

macvm depends on no agent. Any agent that can run commands can use the CLI, and the exit codes and JSON output are meant for that.

- **Claude Code:** `macvm setup` installs the skill when `~/.claude` exists. After upgrading macvm, run `macvm integrate claude` to update it.
- **MCP clients:** `macvm mcp` serves the same operations on stdio. It is not registered automatically. For Claude Code: `claude mcp add macvm -- macvm mcp`.

## Design

[docs/DESIGN.md](docs/DESIGN.md) records the choices and reasons: GUI implementation, accessibility limits, host-VM communication, and what was learned from other projects.

- **VM:** `tart run --no-graphics`, with no window, audio, clipboard or USB sharing and no shared directories. VM storage stays in Tart's own area (`~/.tart`).
- **Guest layout:** apps in `~/macvm/apps/<id>/`, and each launch's stdout and stderr in `~/macvm/runs/<id>/<timestamp>/`.
- **Host state:** `~/.local/state/macvm/`: SSH key, lease, screenshots, results.
- **Source layout:** `bin/macvm` VM lifecycle and lock; `lib/` apps, GUI, integrations, MCP; `helper/` the guest-side program; `skill/` the Claude Code skill.

### Locking

Only one session drives the GUI at a time. Each CLI call that sends input renews a lease, and it is written under `lockf(1)`, a kernel lock that cannot go stale. A lease is reclaimed when it idles past its TTL (15 minutes) or when its owner's process has died. Other sessions wait up to 5 minutes, then exit 75. Reading UI elements takes no lock.

The owner is the nearest long-lived ancestor process: your interactive shell, or the agent process, skipping shells spawned per command. Set `MACVM_SESSION` (and optionally `MACVM_SESSION_PID`) to name it explicitly. Subagents of one agent process share a lease.

## Signing, Gatekeeper and TCC

- arm64 code must be signed. `macvm install --adhoc-sign` applies an ad-hoc signature inside the VM, and the host's copy stays unchanged.
- The transfer carries no quarantine flag, and macvm removes any that came along, so Gatekeeper does not prompt.
- Apps with a device-bound provisioning profile or restricted entitlements will not launch in the VM as built. Ad-hoc re-signing may remove what those entitlements enable.
- TCC prompts raised by the app under test (camera, files, and so on) appear in the VM. Handle them with GUI commands.

## Configuration

Environment variables: `MACVM_NAME`, `MACVM_IMAGE`, `MACVM_CPU`, `MACVM_MEMORY`, `MACVM_DISPLAY` (these three apply when the VM is first created), `MACVM_LOCK_TTL`, `MACVM_LOCK_WAIT`, `MACVM_SESSION`, `MACVM_SESSION_PID`, `MACVM_STATE`, `MACVM_HELPER`, `TART_HOME`.

## Limitations

- **SIP is disabled in the guest.** The Cirrus Labs `base` image ships that way, and it is how the image pre-grants TCC permissions. Together with the point below, this makes the VM a test environment and not a sandbox: do not run untrusted apps in it. Behaviour that depends on SIP may differ from a normal Mac.
- The guest's GUI password stays `admin`, because auto-login depends on it. The guest is reachable only through the host's private NAT network, and SSH password login is off.
- Permissions are granted to the guest agent's versioned path, so upgrading `tart-guest-agent` inside the VM loses them. `macvm status` shows the state. Do not upgrade it there.
- macOS asks now and then whether the guest agent may capture the screen. `setup` and `screenshot` answer this one prompt in the VM. It could still appear between screenshots and take the front until the next `screenshot`.
- Booting a macOS guest needs the host's login keychain unlocked, which a normal GUI login does. Over SSH to a headless Mac it fails with a security error.
- The guest can reach the internet and the host's NAT gateway.
- No Apple ID or iCloud features, audio, or host clipboard. Apple's license limits a host to two concurrent macOS VMs.
- `macvm view --open` opens Screen Sharing on the host, which does take focus. Nothing runs it automatically.

## Development

```bash
make            # builds build/macvm-helper
bin/macvm help  # runs from the checkout
test/verify.sh  # end-to-end against the real VM; add --stop to test shutdown
```

## License

macvm is released under the [MIT License](LICENSE). It does not bundle Tart or macOS images: those are downloaded by `macvm setup` under their own terms.
