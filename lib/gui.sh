# GUI operations: thin host-side wrappers; the work happens in the guest helper.
# Sourced by bin/macvm.

gui_cmd() { acquire_lease; require_running; helper "$@"; }

# Reads take no lock, so another session can look while one is testing. Writes do.
cmd_ui() {
  local action=${1:-}
  case "$action" in
    elements|tree|text|find|wait) require_running; helper ui "$@" ;;
    click|type|focus|menu) gui_cmd ui "$@" ;;
    ''|help|-h|--help) usage ;;
    *) die "unknown ui command: $action (see: macvm help)" ;;
  esac
}

cmd_wait() {
  local seconds=${1:-}
  case "$seconds" in ''|*[!0-9.]*) die "usage: macvm wait SECONDS" ;; esac
  sleep "$seconds"
  # A long wait counts as activity, so the lease must not lapse during it.
  if lease_live && lease_owner && [ "$(lease_field owner)" = "$OWNER" ]; then acquire_lease; fi
}

poll_until() { # timeout description helper-args...
  local timeout=$1 what=$2
  shift 2
  local deadline=$(( $(date +%s) + timeout )) out
  while :; do
    if out=$(helper "$@" 2>/dev/null) && [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
    [ "$(date +%s)" -lt "$deadline" ] || { err "timed out after ${timeout}s waiting for $what"; return 3; }
    sleep 1
  done
}

cmd_wait_window() {
  local id=${1:-} timeout=${2:-20}
  [ -n "$id" ] || die "usage: macvm wait-window BUNDLE_ID [TIMEOUT]"
  acquire_lease; require_running
  poll_until "$timeout" "a window of $id" windows "$id"
}

# A capture can raise macOS's consent dialog shortly afterwards. Left open, it holds
# the front and later commands go to the wrong app. Checks ATTEMPTS times.
answer_capture_prompt() {
  local attempts=$1 i=0
  while [ "$i" -lt "$attempts" ]; do
    if helper allow-capture-prompt 2>/dev/null | jq -e '.allowed == true' >/dev/null; then
      info "answered the screen capture prompt"
      sleep 0.5
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] && sleep 0.5
  done
  return 1
}

cmd_screenshot() {
  local out="" raw=no window="" region=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output) out=${2:?}; shift 2 ;;
      --raw) raw=yes; shift ;;
      --window) window=${2:?}; shift 2 ;;
      --region) region=${2:?}; shift 2 ;;
      *) die "usage: macvm screenshot [-o FILE] [--window ID] [--region X,Y,W,H] [--raw]" ;;
    esac
  done
  acquire_lease; require_running
  [ -n "$out" ] || out="$STATE/screenshots/$(date +%Y%m%d-%H%M%S)-$$.png"
  mkdir -p "$(dirname "$out")"
  local remote="/tmp/macvm-shot-$$.png" flags=(-x -t png)
  [ -n "$window" ] && flags+=(-l "$window")
  [ -n "$region" ] && flags+=(-R "$region")
  answer_capture_prompt 1 || true
  gui /usr/sbin/screencapture "${flags[@]}" "$remote" || die "screencapture failed in the VM"
  answer_capture_prompt 2
  scp -q "${SSH_OPTS[@]}" "$GUEST_USER@[$(vm_ip)]:$remote" "$out" || die "could not download the screenshot"
  gssh "rm -f $(sq "$remote")" || true
  # Scale full-screen captures to points, so image coordinates equal click coordinates.
  if [ "$raw" = no ] && [ -z "$window" ] && [ -z "$region" ]; then
    local width
    width=$(helper screen | head -1 | jq -r '.width | floor')
    /usr/bin/sips --resampleWidth "$width" "$out" >/dev/null 2>&1 || err "warning: could not rescale the screenshot"
  fi
  echo "$out"
}
