# macvm design notes

Why macvm is built the way it is. Measurements were taken on an Apple M4 host running macOS 26.2 with a macOS Tahoe guest (`macos-tahoe-base`, Tart 2.41.1), in November 2026.

## Goals, in order

1. The host's cursor, keyboard and focus are never touched.
2. An agent can test an app autonomously and trust the result.
3. One small tool, installable on its own, tied to no AI agent.

## GUI implementation: a stateless helper in the guest

Everything that touches the GUI is `helper/*.swift`, compiled on the host, copied into the VM, and started once per operation by `tart exec`.

| Option | Decision | Reason |
| --- | --- | --- |
| Stateless helper via `tart exec` | **Chosen** | About 125 ms per call. No daemon to keep alive, restart or version. A crash affects one call. |
| Long-running agent in the guest | Rejected | It would need its own protocol, lifecycle and TCC grant, to save latency that does not matter next to UI response times. |
| Input from the host (VNC, `VZVirtualMachineView`) | Rejected | Needs a session attached to the VM, and gives no accessibility data. |
| `cliclick` | Rejected | No scrolling, no accessibility, and a brew dependency in the guest. |

The helper refuses to run unless `kern.hv_vmm_present` is 1. This is the last line of defence for goal 1: pointing it at the host by mistake does nothing.

Modifier keys are posted as real key-down and key-up events, because flags on the key event alone left keyboard input dead after `cmd+a` in testing.

## Accessibility: how it is used, and its limits

**Reading.** `AXUIElement` from the app's root. The walk covers what a user can currently reach: the focused window with its sheets, dialogs and panels above it, and the menu bar with any open menu. Windows behind the front one are excluded (`--all` includes them), because their controls are covered. Walks have node and depth budgets, and a 3-second messaging timeout, so a large or hung app cannot stall a call.

**Naming.** A control's visible name is often not in `AXTitle`, so `label` tries title, description, placeholder, linked title element, nested text (rows, cells, links, buttons), and help text. Matching ignores case, accents and character width, and an exact match beats a partial one. A row and a nested cell with the same name count as one element; without this, System Settings was ambiguous everywhere.

**Output for agents.** `ui elements` lists only controls, one compact JSON object per line, with a header naming the app and window. On Calculator this is 2.6 KB against 1.8 MB for a screenshot. `ui tree` gives the full hierarchy, and `ui text` gives reading-order text, which reads exact values better than OCR on an image does.

**Acting: real input by default.** `ui click` finds the element, then posts a real mouse click at its centre. AXPress alone would "succeed" on a control no user could click, and a test that passes for an impossible action is worse than no test. So it first:

- refuses a disabled element (exit 6)
- hit-tests the point with `AXUIElementCopyElementAtPosition`, and if something else is on top, tries `AXScrollToVisible`, then refuses and names what is covering it (exit 7)
- refuses an ambiguous selector and lists the candidates (exit 8)

`--press` opts into AXPress, and `--force` skips these checks. `ui type` focuses the element and sends real keystrokes so change handlers run; `--set` writes `AXValue` directly. `ui menu` walks from the menu bar with AXPress, because a menu's items have no on-screen frame until it opens.

**Limits.**

- Custom-drawn views, games and canvases expose nothing. The test app's drawing area demonstrates this, and only coordinates reach it.
- Accessibility quality belongs to the app. Unlabelled controls appear only if they have an identifier or take text.
- Secure fields do not report their value, so `ui type` cannot confirm it.
- WebKit and Electron build their tree on request, so empty reads get one retry. `AXManualAccessibility` is set for Electron and Chromium. This was **not tested** against an Electron app.
- Appearance is invisible to accessibility, so checking layout and rendering needs a screenshot.
- `--path` is positional and only valid while the UI is unchanged.

## UI elements or coordinates

| Situation | Use |
| --- | --- |
| A named control | `ui click`, `ui type`, `ui menu` |
| Checking state or waiting | `ui find`, `ui wait`, `ui text` |
| Custom-drawn content, canvases | `screenshot` and `click X Y` |
| Gestures: drag, scroll | Coordinates, using element frames where possible |
| Layout, colour, rendering | `screenshot` |

There is no automatic fallback from an element to coordinates. A failed selector usually means the UI is not in the expected state, so clicking somewhere anyway could hide the bug. The error says what happened and suggests coordinates, and the caller decides. All coordinates share one space: global points, used by `ui` frames, input commands and full-screen screenshots, which are scaled to match.

## Host and VM communication

| Channel | Used for | Reason |
| --- | --- | --- |
| `tart exec` (gRPC to `tart-guest-agent`) | GUI commands, screen capture | The agent runs in the logged-in Aqua session and holds the TCC grants. Arguments need no shell quoting. It also needs no credentials, so it can install the SSH key. |
| SSH, with a dedicated key | Files, logs, shutdown, debugging | Standard and fast. `-F /dev/null` plus its own key and known-hosts file, so the user's SSH setup is not read or changed. `shutdown` through `tart exec` did not take effect in testing, so it goes over SSH. |
| Shared directories | Not used | `tart run --dir` is fixed at boot, and not sharing anything means no host files are exposed. |

### TCC

The `base` image writes grants into TCC.db at build time, which requires SIP to be off in the guest. macvm does not change TCC or SIP itself; it verifies the grants during `setup` and reports them in `status`. An earlier version of this project's notes wrongly said SIP stays on.

The grants name `tart-guest-agent` by its versioned Cellar path and `sshd-keygen-wrapper`, so upgrading the guest agent inside the VM would lose them.

## Keeping the guest's front window predictable

Commands without `--app` act on the frontmost app, so anything taking the front during a test sends input to the wrong place. Two sources were found by testing on a freshly created VM:

- **The consent dialog** above.
- **Terminal,** which the base image opens at every login, and System Settings, which sometimes reopens for a reason not established. `start` closes both.

Removing `~/Library/Preferences/ByHost/com.apple.loginwindow.*` must be avoided. A step-by-step experiment on a disposable VM showed that it makes Setup Assistant take over at every login. Turning off automatic update checks did not cause this, but macvm leaves them alone anyway.

## Separation

- **VM management** (`bin/macvm`): lifecycle, setup, lock.
- **GUI** (`lib/gui.sh` on the host, `helper/` in the guest).
- **Apps and output** (`lib/apps.sh`).
- **Agents** (`lib/integrations.sh`, `lib/mcp.sh`, `skill/`): optional, and the core has no knowledge of them. The lock identifies owners from the process tree, not from any agent's environment variables.

## Agent integration: CLI and skill first, MCP optional

A skill plus the CLI is the default for Claude Code. It costs context only when used, its output can be piped through `jq` and `grep`, and it works for anything that can run a command. Chat Computer's regression numbers show CLI and MCP completing the same 20 tasks, so reliability does not force a choice.

MCP exists for clients that only speak MCP. `macvm mcp` is a thin JSON-RPC loop over a table mapping each tool to its CLI command, so the lock, exit codes and behaviour are shared and there is one vocabulary. It returns screenshots as image content. It is not registered automatically, since a tool list adds to every session's context.

The server was tested at the protocol level, not from a real MCP client.

## Other projects

Neither project is a dependency. **No code was copied from either.** macvm's code was written for this project, so no third-party notices are required; if code is reused later, it must keep the notices its license requires.

### Chat Computer (Apache-2.0) — github.com/chatcomputer/chatcomputer, reviewed at c774a4c

A native app that runs a VM with its own agent inside, and is also a CLI and MCP server.

| Took the idea | Where in macvm |
| --- | --- |
| Read through AX, click through real input | `ui click` default |
| Scope to the reachable windows; leave out covered ones | `reachableRoots` |
| Sequence of attributes for naming, window-button names | `label` |
| Case, accent and width-insensitive matching | `fold` |
| Compact control lists with budgets; separate reading-order text | `ui elements`, `ui text` |
| Retry an empty read for WebKit | `ui elements`, `resolve` |
| One command vocabulary for CLI and MCP; CLI preferred | `lib/mcp.sh` |

Differences:

- **Added for testing:** refusing disabled, covered and ambiguous targets; selector-based actions in the guest. Chat Computer leaves those decisions to its model, and clicks by coordinates.
- **Not transferable to Tart:** its transport is vsock on a `VZVirtualMachine` it owns in-process. Tart owns that object, so an outside tool cannot open a vsock device on it. `tart exec` fills the role. This follows from the architecture and was not separately tested.
- **Not needed:** its setup operates the guest's Settings UI to grant TCC to a signed agent, with SIP on. That suits a consumer app keeping SIP enabled. macvm uses the image's grants, accepting SIP off.
- **Done differently:** Chat Computer answers the system's consent prompt using on-device text recognition. macvm reads it through accessibility, which needs no OCR.

### tart-skills (MIT) — github.com/jonnyzzz/tart-skills, reviewed at 74345a2

Skills that drive a Tart VM from Linux over SSH, using `tart-remote` and `cliclick`.

| Finding | What macvm did |
| --- | --- |
| Detach `tart run` so the VM outlives the caller | Already done, using `setsid` |
| Guest ignores `tart set --display` on Tahoe and stays at 1024x768 | Confirmed independently; `set-display` uses CoreGraphics, not `displayplacer` |
| Consent dialog for direct screen access | Confirmed: on a new VM the first capture raises it, and it takes the front. `setup` makes that first capture and answers it, and `screenshot` answers it if it returns. Only this exact prompt is answered |
| Host keychain must be unlocked to boot a macOS guest | Documented |
| The base image has SIP off | Checked, and it corrected this project's documentation |
| `ControlMaster` to avoid sshd lockouts | Not adopted: that risk comes from repeated password auth, and macvm uses one key with `IdentitiesOnly`. Bursts of calls passed in testing |
| Unique VM per task | Not adopted: macvm's requirement is one shared VM with a lock |
| Clean up on failure, read state from Tart without bookkeeping | Same approach |

Its skill split (one per concern) suits its size. macvm has one skill because the CLI holds the behaviour and the skill only teaches the workflow.

## Verification

`test/verify.sh` runs end to end against the real VM, and asserts results from the test app's own event log, not from command exit codes. It also covers Calculator and System Settings, since a purpose-built app hides real-world accessibility problems: the row-and-cell ambiguity and the scrolled-away link both appeared only on real apps.
