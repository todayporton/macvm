# Optional agent integrations. The CLI itself knows nothing about any agent.
# Sourced by bin/macvm.

CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
MANAGED_MARK="managed-by: macvm"
BLOCK_BEGIN="<!-- macvm:begin (managed by \`macvm integrate claude\`) -->"
BLOCK_END="<!-- macvm:end -->"

# Prints FILE without the managed block.
strip_block() {
  # Blank lines just before the block were added with it, so they go too; otherwise
  # each re-run would grow the file.
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0==b { s=1; blanks=0; next }
    $0==e { s=0; next }
    s { next }
    /^$/ { blanks++; next }
    { while (blanks > 0) { print ""; blanks-- } print }
    END { while (blanks > 0) { print ""; blanks-- } }' "$1"
}

cmd_integrate() {
  local target=${1:-} mode=${2:-}
  [ "$target" = claude ] || die "usage: macvm integrate claude [--remove]"
  local skill_dir="$CLAUDE_DIR/skills/macvm" md="$CLAUDE_DIR/CLAUDE.md" tmp

  if [ "$mode" = --remove ]; then
    if [ -f "$skill_dir/SKILL.md" ]; then
      if grep -q "$MANAGED_MARK" "$skill_dir/SKILL.md"; then
        rm -f "$skill_dir/SKILL.md"; rmdir "$skill_dir" 2>/dev/null || true
      else
        err "leaving $skill_dir/SKILL.md: it was not installed by macvm"
      fi
    fi
    if [ -f "$md" ] && grep -qxF "$BLOCK_BEGIN" "$md"; then
      tmp=$(/usr/bin/mktemp "$md.XXXXXX")
      strip_block "$md" > "$tmp" && mv -f "$tmp" "$md"
    fi
    echo "removed the Claude Code integration"
    return 0
  fi
  [ -z "$mode" ] || die "usage: macvm integrate claude [--remove]"

  [ -f "$SKILL_SRC" ] || die "$SKILL_SRC is missing"
  if [ -f "$skill_dir/SKILL.md" ] && ! grep -q "$MANAGED_MARK" "$skill_dir/SKILL.md"; then
    die "$skill_dir/SKILL.md exists and was not installed by macvm; not overwriting it"
  fi
  mkdir -p "$skill_dir"
  cp -f "$SKILL_SRC" "$skill_dir/SKILL.md"

  mkdir -p "$CLAUDE_DIR"
  [ -f "$md" ] || : > "$md"
  tmp=$(/usr/bin/mktemp "$md.XXXXXX")
  {
    strip_block "$md"
    printf '\n%s\n' "$BLOCK_BEGIN"
    cat <<'RULES'
# macOS GUI testing
- Run GUI tests of macOS apps in the shared VM through the `macvm` CLI (skill: `macvm`), not on the host.
- Never automate the host Mac's GUI for testing: no moving its cursor, sending it keystrokes, changing its window focus, or launching the app under development on it for GUI checks. Building and CLI work on the host are fine.
- If the VM cannot be used, report that instead of falling back to the host GUI.
RULES
    printf '%s\n' "$BLOCK_END"
  } > "$tmp"
  # Keep the original file's mode (mktemp creates 0600), then swap atomically.
  chmod "$(stat -f %Lp "$md")" "$tmp"
  mv -f "$tmp" "$md"
  echo "integrated with Claude Code: $skill_dir/SKILL.md, block in $md"
}
