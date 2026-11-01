# App transfer, launch and output collection. Sourced by bin/macvm.

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }

cmd_install() {
  local src="" sign=no id
  while [ $# -gt 0 ]; do
    case "$1" in
      --adhoc-sign) sign=yes; shift ;;
      -*) die "usage: macvm install PATH [--adhoc-sign]" ;;
      *) src=$1; shift ;;
    esac
  done
  [ -n "$src" ] || die "usage: macvm install PATH [--adhoc-sign]"
  [ -e "$src" ] || die "no such file: $src"
  src=${src%/}

  local kind exe parent name
  parent=$(cd "$(dirname "$src")" && pwd); name=$(basename "$src")
  case "$name" in
    *.app)
      kind=app
      [ -f "$src/Contents/Info.plist" ] || die "$src has no Contents/Info.plist"
      id=$(plist_get "$src/Contents/Info.plist" CFBundleIdentifier)
      exe=$(plist_get "$src/Contents/Info.plist" CFBundleExecutable)
      [ -n "$id" ] && [ -n "$exe" ] || die "Info.plist lacks CFBundleIdentifier or CFBundleExecutable"
      check_arch "$src/Contents/MacOS/$exe"
      ;;
    *)
      [ -f "$src" ] && [ -x "$src" ] || die "$src is neither an .app bundle nor an executable file"
      kind=binary; id=$name; exe=$name
      check_arch "$src"
      ;;
  esac
  valid_id "$id"

  acquire_lease
  ensure_started

  # Replacing a running app would leave a confusing mix of old and new code.
  if [ "$kind" = app ] && helper app-status "$id" 2>/dev/null | jq -e .running >/dev/null; then
    info "quitting the running copy of $id"
    quit_app "$id" force
  fi

  local dest="$GUEST_ROOT/apps/$id"
  gssh "rm -rf $(sq "$dest") && mkdir -p $(sq "$dest")" || die "could not prepare $dest"
  info "transferring $name to the VM..."
  COPYFILE_DISABLE=1 /usr/bin/tar -cf - -C "$parent" "$name" \
    | gssh "/usr/bin/tar -xf - -C $(sq "$dest") && xattr -dr com.apple.quarantine $(sq "$dest/$name") 2>/dev/null; printf '%s\n' 'kind=$kind' $(sq "name=$name") $(sq "exe=$exe") > $(sq "$dest/.macvm-meta")" \
    || die "transfer failed"

  if [ "$sign" = yes ]; then
    gssh "codesign --force --deep --sign - $(sq "$dest/$name")" || die "ad-hoc signing failed"
  fi
  if ! gssh "codesign --verify --strict $(sq "$dest/$name")" 2>/dev/null; then
    err "warning: the code signature is invalid or missing, and arm64 code will not launch; retry with --adhoc-sign"
  fi
  echo "installed id=$id kind=$kind path=$dest/$name"
}

check_arch() {
  /usr/bin/lipo -archs "$1" 2>/dev/null | grep -w arm64 >/dev/null && return 0
  # Scripts have no architecture and are fine; a Mach-O without arm64 is not.
  /usr/bin/file -b "$1" | grep 'Mach-O' >/dev/null && die "$1 has no arm64 slice (Rosetta is not installed in the VM)"
  return 0
}

meta_read() { # id -> sets M_kind M_name M_exe
  valid_id "$1"
  local meta
  meta=$(gssh "cat $(sq "$GUEST_ROOT/apps/$1/.macvm-meta")" 2>/dev/null) || die "'$1' is not installed in the VM; run: macvm install PATH"
  M_kind=$(printf '%s\n' "$meta" | sed -n 's/^kind=//p')
  M_name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p')
  M_exe=$(printf '%s\n' "$meta" | sed -n 's/^exe=//p')
}

cmd_launch() {
  local id=${1:-}; [ -n "$id" ] || die "usage: macvm launch ID [--timeout SECONDS] [--env K=V]... [-- ARGS...]"
  shift
  local timeout=20 envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout=${2:?}; shift 2 ;;
      --env) envs+=("--env" "${2:?}"); shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) die "unknown option $1 (app arguments go after --)" ;;
    esac
  done
  acquire_lease
  ensure_started
  # Not installed by macvm: launch by bundle id, such as an app that ships with the guest.
  if ! gssh "test -f $(sq "$GUEST_ROOT/apps/$id/.macvm-meta")"; then
    valid_id "$id"
    gui /usr/bin/open -b "$id" ${envs[@]+"${envs[@]}"} ${args[@]+--args "${args[@]}"} \
      || die "'$id' is not installed in the VM; run: macvm install PATH"
    local until=$(( $(date +%s) + timeout ))
    until helper app-status "$id" 2>/dev/null | jq -e '.running and .launched' >/dev/null; do
      [ "$(date +%s)" -lt "$until" ] || die "$id did not finish launching within ${timeout}s"
      sleep 1
    done
    helper app-status "$id"
    return 0
  fi
  meta_read "$id"

  local run="$GUEST_ROOT/runs/$id/$(date +%Y%m%d-%H%M%S)" path="$GUEST_ROOT/apps/$id/$M_name"
  gssh "mkdir -p $(sq "$run") && ln -sfn $(sq "$run") $(sq "$GUEST_ROOT/runs/$id/latest") && date -u +%Y-%m-%dT%H:%M:%SZ > $(sq "$run/started-at")" || die "could not create the run directory"

  if [ "$M_kind" = app ]; then
    gui /usr/bin/open -n --stdout "$run/stdout.log" --stderr "$run/stderr.log" \
      ${envs[@]+"${envs[@]}"} "$path" ${args[@]+--args "${args[@]}"} || die "open failed for $path"
    local deadline=$(( $(date +%s) + timeout ))
    until helper app-status "$id" 2>/dev/null | jq -e '.running and .launched' >/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        err "$id did not finish launching within ${timeout}s. stderr follows:"
        gssh "tail -20 $(sq "$run/stderr.log")" >&2
        exit 1
      fi
      sleep 1
    done
    helper app-status "$id"
  else
    local q=""
    local item
    for item in ${envs[@]+"${envs[@]}"}; do [ "$item" = --env ] || q="$q export $(sq "$item");"; done
    q="$q nohup $(sq "$path")"
    for item in ${args[@]+"${args[@]}"}; do q="$q $(sq "$item")"; done
    guest_shell "$q > $(sq "$run/stdout.log") 2> $(sq "$run/stderr.log") < /dev/null & echo \$! > $(sq "$run/pid"); echo pid=\$!" || die "could not start $path"
  fi
  echo "run=$run"
}

quit_app() { # id [force]
  local id=$1 mode=${2:-}
  valid_id "$id"
  if [ "$mode" != force-only ]; then
    gui /usr/bin/osascript -e "with timeout of 10 seconds" -e "tell application id \"$id\" to quit" -e "end timeout" >/dev/null 2>&1 || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      helper app-status "$id" 2>/dev/null | jq -e '.running | not' >/dev/null && return 0
      sleep 1
    done
  fi
  [ -n "$mode" ] || return 1
  local pid
  pid=$(helper app-status "$id" 2>/dev/null | jq -r '.pid // empty')
  [ -n "$pid" ] || return 0
  err "force-killing $id (pid $pid)"
  gui /bin/kill -9 "$pid"
  sleep 1
}

cmd_quit() {
  local id=${1:-} mode=""
  [ -n "$id" ] || die "usage: macvm quit ID [--force]"
  [ "${2:-}" = --force ] && mode=force
  acquire_lease; require_running
  # A plain binary has no bundle id: stop it by the pid recorded at launch.
  local pidfile="$GUEST_ROOT/runs/$id/latest/pid"
  if gssh "test -f $(sq "$pidfile")" 2>/dev/null; then
    gssh "kill \$(cat $(sq "$pidfile")) 2>/dev/null; rm -f $(sq "$pidfile")"
    echo "stopped $id"; return 0
  fi
  quit_app "$id" "$mode" || die "$id did not quit in time; retry with --force"
  echo "quit $id"
}

# --- Output collection ----------------------------------------------------------

cmd_logs() {
  local id=${1:-} stream=both tail=100
  [ -n "$id" ] || die "usage: macvm logs ID [--stdout|--stderr] [--tail N]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --stdout) stream=stdout; shift ;;
      --stderr) stream=stderr; shift ;;
      --tail) tail=${2:?}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  valid_id "$id"; require_running
  local run="$GUEST_ROOT/runs/$id/latest"
  gssh "test -e $(sq "$run")" || die "no runs recorded for $id"
  if [ "$stream" != stderr ]; then echo "--- stdout"; gssh "tail -n $tail $(sq "$run/stdout.log") 2>/dev/null"; fi
  if [ "$stream" != stdout ]; then echo "--- stderr"; gssh "tail -n $tail $(sq "$run/stderr.log") 2>/dev/null"; fi
}

crash_list() { # exe
  gssh "find ~/Library/Logs/DiagnosticReports -maxdepth 1 -type f -name $(sq "$1-*") 2>/dev/null"
}

cmd_crashes() {
  local id=${1:-}; [ -n "$id" ] || die "usage: macvm crashes ID"
  require_running; meta_read "$id"
  local list
  list=$(crash_list "$M_exe")
  if [ -z "$list" ]; then echo "no crash reports for $M_exe"; else printf '%s\n' "$list"; fi
}

# Copies one run's stdout/stderr, crash reports and unified log to the host.
cmd_collect() {
  local id=${1:-} out="" since=30m
  [ -n "$id" ] || die "usage: macvm collect ID [-o DIR] [--since 30m]"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output) out=${2:?}; shift 2 ;;
      --since) since=${2:?}; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  require_running; meta_read "$id"
  [ -n "$out" ] || out="$STATE/results/$id/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$out/crashes"
  local ip; ip=$(vm_ip)
  scp -q -r "${SSH_OPTS[@]}" "$GUEST_USER@[$ip]:$GUEST_ROOT/runs/$id/latest/" "$out/run" 2>/dev/null || err "warning: no run directory to copy"
  local report
  crash_list "$M_exe" | while IFS= read -r report; do
    [ -n "$report" ] && scp -q "${SSH_OPTS[@]}" "$GUEST_USER@[$ip]:$report" "$out/crashes/" </dev/null
  done
  gssh "/usr/bin/log show --last $(sq "$since") --style compact --predicate $(sq "process == \"$M_exe\"")" > "$out/unified.log" 2>/dev/null || err "warning: could not read the unified log"
  echo "$out"
}

cmd_clean() {
  local target=${1:-}
  [ -n "$target" ] || die "usage: macvm clean ID | --all | --host"
  case "$target" in
    --host)
      rm -rf "$STATE/screenshots" "$STATE/results"
      mkdir -p "$STATE/screenshots" "$STATE/results"
      echo "removed host-side screenshots and results"; return 0 ;;
  esac
  acquire_lease; require_running
  if [ "$target" = --all ]; then
    local ids id
    ids=$(gssh "ls $(sq "$GUEST_ROOT/apps") 2>/dev/null")
    for id in $ids; do clean_one "$id"; done
    gssh "rm -rf $(sq "$GUEST_ROOT/apps") $(sq "$GUEST_ROOT/runs"); mkdir -p $(sq "$GUEST_ROOT/apps") $(sq "$GUEST_ROOT/runs"); rm -f /tmp/macvm-shot-*.png"
    rm -rf "$STATE/screenshots" "$STATE/results"
    mkdir -p "$STATE/screenshots" "$STATE/results"
    echo "cleaned every app, run and screenshot"
  else
    clean_one "$target"
    echo "cleaned $target"
  fi
}

clean_one() {
  local id=$1
  meta_read "$id"
  quit_app "$id" force-only 2>/dev/null || true
  if gssh "test -f $(sq "$GUEST_ROOT/runs/$id/latest/pid")" 2>/dev/null; then
    gssh "kill \$(cat $(sq "$GUEST_ROOT/runs/$id/latest/pid")) 2>/dev/null" || true
  fi
  crash_list "$M_exe" | while IFS= read -r report; do
    [ -n "$report" ] && gssh "rm -f $(sq "$report")" </dev/null
  done
  gssh "rm -rf $(sq "$GUEST_ROOT/apps/$id") $(sq "$GUEST_ROOT/runs/$id")"
}
