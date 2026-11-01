#!/bin/bash
# End-to-end check against the real VM. Builds a small test app on the host, runs
# it only in the VM, and asserts each input from the app's own event log. A watcher
# samples the host's cursor and frontmost app throughout.
#
# Usage: test/verify.sh [--stop]   --stop also tests shutting the VM down.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
export PATH="$here/../bin:$HOME/.local/bin:$PATH"
ID=dev.macvm.test
work=$(mktemp -d)
pass=0; fail=0
watcher=""
cleanup() { [ -n "$watcher" ] && kill "$watcher" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

ok() { pass=$((pass+1)); printf 'PASS  %s\n' "$1"; }
ng() { fail=$((fail+1)); printf 'FAIL  %s  %s\n' "$1" "${2:-}"; }
check() { local name=$1; shift; if "$@" >"$work/out" 2>&1; then ok "$name"; else ng "$name" "$(tail -3 "$work/out")"; fi; }
events() { macvm logs "$ID" --stdout --tail 500; }
saw() { # name pattern: waits briefly for an EVENT line
  local i
  for i in 1 2 3 4 5 6; do
    if events | grep -- "$2" >/dev/null; then ok "$1"; return; fi
    sleep 0.5
  done
  ng "$1" "no '$2' in the app's event log"
}

# Host probe: reads cursor and frontmost app, needs no permissions, posts nothing.
probe() {
  /usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); const p=$.NSEvent.mouseLocation; const a=$.NSWorkspace.sharedWorkspace.frontmostApplication; Math.round(p.x)+","+Math.round(p.y)+" "+ObjC.unwrap(a.bundleIdentifier)' 2>/dev/null
}
watch_host() { while :; do probe; sleep 0.25; done > "$work/host.log"; }

check "VM starts" macvm start
check "SSH with key" macvm ssh true
check "password login is disabled" sh -c "macvm ssh 'sudo -n sshd -T 2>/dev/null | grep -qx \"passwordauthentication no\"'"
check "helper runs inside a VM" sh -c "macvm ssh sysctl -n kern.hv_vmm_present | grep -qx 1"

watch_host & watcher=$!
sleep 1

app=$("$here/build-test-app.sh" "$work") || { ng "build test app"; exit 1; }
check "install .app" macvm install "$app"
check "launch app" macvm launch "$ID"
check "window appears" macvm wait-window "$ID" 15
sleep 1
saw "stdout captured" hello-stdout
macvm logs "$ID" --stderr | grep hello-stderr >/dev/null && ok "stderr captured" || ng "stderr captured"
check "activate" macvm activate "$ID"
macvm windows "$ID" | jq -e 'select(.title == "macvm test")' >/dev/null && ok "window list has the title" || ng "window list has the title"
macvm app-status "$ID" | jq -e '.running and .active' >/dev/null && ok "app-status" || ng "app-status"

# --- UI elements first ---
macvm ui elements --app "$ID" > "$work/elements" 2>&1
jq -e -s '.[0].bundleId == "'$ID'" and .[0].window == "macvm test"' "$work/elements" >/dev/null && ok "ui elements: header" || ng "ui elements: header" "$(head -2 "$work/elements")"
jq -e -s 'any(.[]; .role == "button" and .label == "保存" and (.frame | length) == 4)' "$work/elements" >/dev/null && ok "ui elements: role, Japanese label, frame" || ng "ui elements: role, Japanese label, frame"
jq -e -s 'any(.[]; .id == "input" and .role == "textfield" and .label == "type here")' "$work/elements" >/dev/null && ok "ui elements: id, placeholder as label" || ng "ui elements: id, placeholder as label"
jq -e -s 'any(.[]; .label == "Disabled" and .enabled == false)' "$work/elements" >/dev/null && ok "ui elements: disabled state" || ng "ui elements: disabled state"
if jq -e -s 'any(.[]; .label == "Do Thing")' "$work/elements" >/dev/null; then ng "closed menu items are left out"; else ok "closed menu items are left out"; fi
macvm ui tree --app "$ID" --depth 4 | jq -e -s 'length > 5 and any(.[]; .role == "window")' >/dev/null && ok "ui tree" || ng "ui tree"
macvm ui text | grep idle >/dev/null && ok "ui text (frontmost app)" || ng "ui text"
macvm ui find --query x >/dev/null 2>&1; [ $? -eq 2 ] && ok "bad option is a usage error" || ng "bad option is a usage error"

check "ui click by label, Japanese" macvm ui click --label "保存"
saw "ui click reached the app with a mouse event" saved
check "ui click by id" macvm ui click --id press
saw "ui click by id reached the app" buttonPressed
check "element state readable after the click" macvm ui wait --id status --value pressed --timeout 5
macvm ui click --label "ＰＲＥＳＳ ｍｅ" >/dev/null && ok "label match ignores case and width" || ng "label match ignores case and width"
macvm ui click --id press --press | jq -e '.method == "press"' >/dev/null && ok "ui click --press uses AXPress" || ng "ui click --press uses AXPress"

macvm ui click --label "Disabled" >/dev/null 2>&1; [ $? -eq 6 ] && ok "disabled element is refused (6)" || ng "disabled element is refused"
macvm ui click --label "no such thing" >/dev/null 2>"$work/err"; rc=$?; [ $rc -eq 3 ] && grep 'screenshot' "$work/err" >/dev/null && ok "missing element points to coordinates (3)" || ng "missing element" "$rc $(cat "$work/err")"
macvm ui click --role button >/dev/null 2>&1; [ $? -eq 8 ] && ok "ambiguous selector is refused (8)" || ng "ambiguous selector is refused"
macvm ui find --role button | wc -l | tr -d ' ' | grep -E '^[3-9]$|^[1-9][0-9]$' >/dev/null && ok "ui find lists matches" || ng "ui find lists matches"

check "open a covering panel" macvm ui click --label Cover
saw "panel is shown" coverShown
macvm ui click --id press >/dev/null 2>"$work/err"; rc=$?; [ $rc -eq 7 ] && ok "covered element is refused (7): $(cut -c1-90 "$work/err")" || ng "covered element is refused" "$rc $(cat "$work/err")"
check "ui menu" macvm ui menu Tools "Hide Cover"
saw "menu item reached the app" coverHidden
check "ui click works once uncovered" macvm ui click --id press
macvm ui menu Tools nothing >/dev/null 2>"$work/err"; [ $? -eq 3 ] && grep 'Do Thing' "$work/err" >/dev/null && ok "unknown menu item lists choices" || ng "unknown menu item" "$(cat "$work/err")"

macvm ui type --id input "by element" | jq -e '.value == "by element"' >/dev/null && ok "ui type returns the new value" || ng "ui type returns the new value"
saw "ui type sent real keystrokes" "text=by element"
macvm ui type --id input --replace "置換" | jq -e '.value == "置換"' >/dev/null && ok "ui type --replace" || ng "ui type --replace"
macvm ui type --id input --set "direct" | jq -e '.value == "direct"' >/dev/null && ok "ui type --set" || ng "ui type --set"
check "ui wait --gone" macvm ui wait --label "does not exist" --gone --timeout 2
macvm ui type --id input --replace "" >/dev/null 2>&1

# --- Coordinates: the fallback, with frames from UI elements ---
macvm ui click --id input >/dev/null
macvm key cmd+a >/dev/null; macvm key delete >/dev/null
read -r fx fy fw fh < <(macvm ui find --id input | jq -r '.frame | map(tostring) | join(" ")')
check "click text field" macvm click $((fx + fw / 2)) $((fy + fh / 2))
check "type" macvm type "Hello macvm"
saw "typed text arrived" "text=Hello macvm"
check "key shortcut cmd+a" macvm key cmd+a
check "type replaces selection" macvm type "ありがとう"
saw "shortcut and unicode worked" "text=ありがとう"

# The drop area is a custom-drawn view with no accessibility, so only coordinates reach it.
read -r wx wy wh < <(macvm windows "$ID" | jq -r '[.x, .y, .height] | map(floor | tostring) | join(" ")')
ax=$((wx + 120)); ay=$((wy + wh - 100))
check "click" macvm click "$ax" "$ay"
saw "click reached the app" "mouseDown count=1"
check "double click" macvm doubleclick "$ax" "$ay"
saw "double click reached the app" "mouseDown count=2"
check "right click" macvm rightclick "$ax" "$ay"
saw "right click reached the app" rightMouseDown
macvm key escape >/dev/null 2>&1
check "scroll" macvm scroll 3 --at "$ax,$ay"
saw "scroll reached the app" "scroll dy="
check "drag" macvm drag "$ax" "$ay" $((ax + 120)) $((ay + 40))
saw "drag reached the app" dragEnded

shot=$(macvm screenshot) && [ -s "$shot" ] && ok "screenshot: $shot" || ng "screenshot"
width=$(sips -g pixelWidth "$shot" | awk '/pixelWidth/{print $2}')
screen=$(macvm screen | head -1 | jq -r '.width | floor')
[ "$width" = "$screen" ] && ok "screenshot pixels equal points ($width)" || ng "screenshot scale" "$width vs $screen"

# --- MCP: same operations over stdio ---
mcp() { printf '%s\n' "$@" | macvm mcp; }
call() { printf '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2"; }
macvm activate "$ID" >/dev/null
mcp "$(call ui_click '{"label":"保存"}')" | jq -e '.result.isError == false' >/dev/null && ok "MCP ui_click" || ng "MCP ui_click"
mcp "$(call ui_type '{"id":"input","text":"--via mcp","replace":true}')" | jq -e '.result.content[0].text | fromjson | .value == "--via mcp"' >/dev/null && ok "MCP ui_type with text like an option" || ng "MCP ui_type with text like an option"
mcp "$(call ui_click '{"label":"Disabled"}')" | jq -e '.result.isError == true and (.result.content[0].text | contains("disabled"))' >/dev/null && ok "MCP reports errors" || ng "MCP reports errors"
mcp "$(call screenshot '{}')" | jq -e '.result.content[0].type == "image" and (.result.content[0].data | length) > 1000' >/dev/null && ok "MCP screenshot returns an image" || ng "MCP screenshot"
mcp "$(call nope '{}')" | jq -e '.error.code == -32602' >/dev/null && ok "MCP unknown tool" || ng "MCP unknown tool"

# Another directory, same VM and tools.
(cd / && macvm status | grep 'running: true' >/dev/null) && ok "usable from another directory" || ng "usable from another directory"

# Locking: a second session must be refused, then get in once the first lets go.
check "take lock" macvm lock
if MACVM_SESSION=verify-other MACVM_LOCK_WAIT=2 macvm move 5 5 >"$work/out" 2>&1; then
  ng "second session is refused" "it was allowed in"
else
  [ $? -eq 75 ] && ok "second session is refused (exit 75)" || ng "second session is refused" "$(cat "$work/out")"
fi
check "release lock" macvm unlock
check "second session gets in" env MACVM_SESSION=verify-other macvm lock --ttl 1
sleep 2
check "expired lock is reclaimed" macvm lock
macvm unlock >/dev/null
(sleep 300 & echo $! > "$work/pid"; wait) &
sleep 0.5; deadpid=$(cat "$work/pid")
MACVM_SESSION=verify-dead MACVM_SESSION_PID=$deadpid macvm lock >/dev/null
kill "$deadpid"; sleep 0.5
check "dead owner's lock is reclaimed" env MACVM_LOCK_WAIT=2 macvm lock
macvm unlock >/dev/null

check "quit" macvm quit "$ID"
macvm app-status "$ID" | jq -e '.running | not' >/dev/null && ok "app is gone" || ng "app is gone"
saw "app saw terminate" terminated
res=$(macvm collect "$ID") && [ -s "$res/run/stdout.log" ] && ok "collect: $res" || ng "collect"
rm -rf "$res"
rm -f "$shot"
check "clean" macvm clean "$ID"
if macvm ssh "test -e ~/macvm/apps/$ID"; then ng "clean removed the app"; else ok "clean removed the app"; fi

# Plain executable.
printf '#!/bin/sh\necho hi-from-binary\n' > "$work/mybin"; chmod +x "$work/mybin"
check "install binary" macvm install "$work/mybin"
check "launch binary" macvm launch mybin
sleep 1
macvm logs mybin --stdout | grep hi-from-binary >/dev/null && ok "binary stdout" || ng "binary stdout"
check "clean binary" macvm clean mybin
macvm unlock >/dev/null

# --- Real apps, which expose accessibility differently from the test app ---
C=com.apple.calculator
macvm launch "$C" >/dev/null && macvm wait-window "$C" 10 >/dev/null; sleep 1
for k in 7 Multiply 6 Equals; do macvm ui click --app "$C" --label "$k" >/dev/null || ng "Calculator: $k"; done
sleep 0.5
macvm ui text --app "$C" | grep 42 >/dev/null && ok "Calculator: 7 x 6 = 42 through UI elements only" || ng "Calculator"
macvm quit "$C" >/dev/null
P=com.apple.systempreferences
macvm launch "$P" --timeout 20 >/dev/null; sleep 3
macvm ui click --app "$P" --label Appearance >/dev/null && ok "System Settings: row with a nested cell is not ambiguous" || ng "System Settings"
macvm ui wait --app "$P" --label "Text size" --timeout 5 >/dev/null || macvm ui wait --app "$P" --label "Light" --timeout 5 >/dev/null && ok "System Settings: the pane changed" || ng "System Settings: the pane changed"
macvm quit "$P" --force >/dev/null
macvm unlock >/dev/null

kill "$watcher" 2>/dev/null; watcher=""
samples=$(wc -l < "$work/host.log" | tr -d ' ')
apps=$(awk '{print $2}' "$work/host.log" | sort -u | tr '\n' ' ')
states=$(sort -u "$work/host.log" | wc -l | tr -d ' ')
echo "--- host: $samples samples, $states distinct states, frontmost apps: $apps"
# macvm must never bring these forward. Cursor movement alone cannot be judged here,
# because the person using this Mac moves it too: it proves something only when idle.
case " $apps " in
  *" dev.macvm.test "*|*Tart*|*tart*) ng "host focus was not taken" "$apps" ;;
  *) ok "host focus was not taken by the VM or the test app" ;;
esac
if [ "$states" -eq 1 ]; then ok "host cursor and frontmost app did not change at all"
else echo "NOTE  the host state changed; expected if someone was using this Mac"; fi

if [ "${1:-}" = --stop ]; then
  check "VM stops" macvm stop
  grep 'forcing the VM to stop' "$work/out" >/dev/null && ng "shutdown was graceful" "it had to be forced" || ok "shutdown was graceful"
  macvm status | grep 'running: false' >/dev/null && ok "status reports stopped" || ng "status reports stopped"
fi

echo "=== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
