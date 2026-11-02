---
name: macvm
description: Run GUI tests and visual checks of native macOS apps inside a shared headless VM, without touching the host Mac's mouse, keyboard or window focus. Use whenever asked to launch, click through, screenshot or verify the behaviour of a macOS app (.app, Xcode or SwiftPM project), and instead of any host GUI automation.
---
<!-- managed-by: macvm. `macvm integrate claude` overwrites this file; `--remove` deletes it. -->

# macOS GUI testing with macvm

All GUI work happens in the VM through the `macvm` CLI. Building and CLI work on the host are fine. Never launch the app under test on the host, and never use `open`, `osascript`, `cliclick` or computer-use tools against the host for testing. If the VM cannot be used, report that rather than falling back to the host.

## Workflow

1. **Check the VM.** Run `macvm status`. If `macvm` is not found, tell the user to install it. If the VM does not exist, run `macvm setup` (the first run downloads about 26 GB, so run it in the background and confirm with the user first). Otherwise run `macvm start`.
2. **Build on the host and find the artifact.**
   - Xcode: `xcodebuild -scheme S -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build`, artifact in `build/Build/Products/Debug/*.app`. If the scheme is unknown, use `xcodebuild -list` first.
   - SwiftPM: `swift build -c debug`, then `swift build --show-bin-path` gives the executable's directory.
   - Otherwise search the project's build output with `find . -name '*.app' -maxdepth 6`.
3. **Install.** `macvm install PATH` prints `id=...`. Use `--adhoc-sign` if it warns about the signature.
4. **Launch.** `macvm launch ID [--env K=V] [-- ARGS...]`, then `macvm wait-window ID`.
5. **Drive and observe**, as below.
6. **Collect.** `macvm logs ID`, `macvm crashes ID`, `macvm collect ID` (prints a directory on the host).
7. **Clean up.** `macvm quit ID`, `macvm clean ID`, `macvm unlock`. Run `macvm stop` when no more testing is expected, since the VM should run only when needed.

## Driving the app

Use UI elements first. Reading them is much cheaper than a screenshot, they survive layout changes, and they tell you what is enabled and what it contains.

```bash
macvm ui elements                       # controls in reach, frontmost app. --app ID, --query save
macvm ui click --label 保存             # a real mouse click at the element's centre
macvm ui type --id searchField "hello"  # focuses, then types real keys; prints the new value
macvm ui type --id name --replace "x"   # replaces the content
macvm ui menu File "Save As…"
macvm ui wait --id status --value done --timeout 10
macvm ui wait --label Loading --gone
macvm ui text                           # the window's text, including what is scrolled away
macvm ui tree --depth 6                 # full hierarchy, when elements is not enough
```

Selectors: `--label` matches the visible name, ignoring case and width, and prefers an exact match. `--id` is exact. `--role` takes `button` or `AXButton`. `--value` matches content. `--path` comes from an earlier listing and is valid only while the UI is unchanged. Combine them to narrow down; `--all` also searches windows behind the front one.

A refusal is information about the app, so do not force past it without a reason:

| Exit | Meaning | What to do |
| --- | --- | --- |
| 3 | No such element | `ui elements`, then coordinates if the app does not expose it |
| 6 | Disabled | Possibly the bug you are testing. Report it, or fix the precondition |
| 7 | Covered: the message names what is on top | Deal with that dialog or panel. `--force` only if deliberate |
| 8 | Ambiguous: the message lists candidates | Narrow the selector or pass `--index` |

`ui click --press` uses AXPress instead of the mouse, for controls that are hard to hit. It skips hit testing, so it proves less.

**Fall back to coordinates** when a control has no accessible element (custom-drawn views, games, canvases) or for gestures:

```bash
macvm screenshot                        # prints a host PNG path: open it with the Read tool
macvm click X Y | doubleclick X Y | rightclick X Y
macvm drag X1 Y1 X2 Y2 | scroll DY [DX] --at X,Y
macvm type "text" | key cmd+a return
macvm windows ID | activate ID | app-status ID | wait SECONDS
```

Coordinates are global points. `ui` frames (`[x, y, width, height]`) and full-screen screenshots share that space, so a frame can guide a coordinate action inside a custom view. Window and region captures have their own origin and are not scaled.

**Use a screenshot to check appearance**: layout, colours, rendering, clipped text. UI elements cannot show those, and a screenshot you did not open proves nothing. Confirm behaviour by reading state (`ui wait`, `ui find`, logs), not by assuming an input worked.

If an unexpected app is frontmost, `ui elements` lists its controls too, so a system dialog can be read and answered the same way.

## Locking

One session drives the GUI at a time. GUI commands take the lock automatically and renew it on each use. It is released by `macvm unlock`, by `macvm stop`, after 15 idle minutes, or when the owning process dies. Exit code 75 means another session held it for the whole 5-minute wait: tell the user, or retry later. Use `macvm unlock --force` only when the holder is known to be gone. Do not stop the VM or force-unlock while another session's lock is live.

## Recovery

| Symptom | Action |
| --- | --- |
| Exit 75 | Another session is testing. Check `macvm lock-status`, then wait or report it. |
| `not running` / agent or SSH failure | `macvm start`. If that fails, `macvm stop`, then `macvm start`, then read `~/.local/state/macvm/tart-run.log`. |
| SSH key rejected | `macvm setup` is safe to re-run and re-installs the key. |
| Permission error (exit 4) | `macvm status` shows the TCC state. `macvm setup` re-checks it. Report it if it stays false. |
| App will not launch | `macvm logs ID --stderr`, `macvm crashes ID`, then retry `install --adhoc-sign`. Debug-signed apps with restricted entitlements or a device-bound provisioning profile need a re-sign, which may remove those capabilities: report that. |
| Stale or hung app | `macvm quit ID --force` |
| Input does nothing | `macvm frontmost`, `macvm activate ID`, then `macvm ui elements` and a screenshot to look for a blocking dialog. |
| Screen capture prompt | `macvm screenshot` answers it. If it took the front between screenshots, run `macvm screenshot` once. |
| VM will not boot with a security error | The host login keychain is locked (no GUI login on the host). Report it to the user. |

Report anything not verified as unverified. Limits: no audio, no host clipboard, no iCloud or Apple ID features, and hardware such as cameras is unavailable.
