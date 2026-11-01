# `macvm mcp`: the CLI's operations as an MCP server (JSON-RPC 2.0, one message per
# line on stdio). Every tool runs the same `macvm` command, so the lock, exit codes and
# behaviour are shared, and there is one vocabulary to maintain. Sourced by bin/macvm.

# name | description | CLI words | positional properties | properties ("name:type", flag from name)
MCP_TOOLS='status|VM state, permissions and lock|status||
start|Boot the VM headless (idempotent)|start||
stop|Shut the VM down|stop||
install|Copy a host .app or executable into the VM; prints its id|install|path|adhoc-sign:boolean
launch|Launch an installed app or a bundle id in the VM|launch|id|timeout:string
quit|Quit an app in the VM|quit|id|force:boolean
app_status|Whether an app runs, is active, and its window titles|app-status|id|
windows|List on-screen windows, optionally for one bundle id|windows|id?|
activate|Bring an app to the front|activate|id|
ui_elements|Interactive controls of the frontmost or given app, with labels, values, ids and frames. Start here|ui elements||app:string query:string all:boolean
ui_tree|Full accessibility hierarchy|ui tree||app:string depth:string menu:boolean all:boolean
ui_text|Text of the front window in reading order|ui text||app:string
ui_find|Find elements by selector|ui find||app:string label:string id:string role:string value:string path:string all:boolean
ui_click|Click an element by selector. Fails if it is disabled, covered or ambiguous|ui click||app:string label:string id:string role:string value:string path:string index:string press:boolean double:boolean right:boolean force:boolean
ui_type|Focus an element by selector and type text into it|ui type|text|app:string label:string id:string role:string value:string path:string index:string replace:boolean set:boolean
ui_menu|Choose a menu item, given names in order from the menu bar|ui menu|items*|app:string
ui_wait|Wait for an element to appear, or to go away with gone|ui wait||app:string label:string id:string role:string value:string path:string gone:boolean timeout:string
screenshot|Capture the VM screen; image pixels match click coordinates|screenshot||
click|Click at coordinates, for what ui_click cannot reach|click|x y|
double_click|Double-click at coordinates|doubleclick|x y|
right_click|Right-click at coordinates|rightclick|x y|
drag|Drag between coordinates|drag|x1 y1 x2 y2|
scroll|Scroll lines; positive dy is down. at is "X,Y"|scroll|dy|at:string
key|Press key combos such as cmd+a or return|key|combos*|
type|Type text into the focused control|type|text|
wait|Sleep for some seconds|wait|seconds|
logs|An app'"'"'s stdout and stderr from its last launch|logs|id|tail:string
crashes|Crash reports for an app|crashes|id|
collect|Copy logs and crash reports to the host; prints the directory|collect|id|
clean|Remove an app and its logs from the VM|clean|id|
unlock|Release this session'"'"'s GUI lock|unlock||'

mcp_tools_json() {
  printf '%s\n' "$MCP_TOOLS" | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("|")) | map({
      name: .[0], description: .[1], cli: (.[2] | split(" ")),
      positional: ((.[3] // "") | split(" ") | map(select(length > 0))),
      options: ((.[4] // "") | split(" ") | map(select(length > 0) | split(":") | {name: .[0], type: .[1]}))
    })'
}

mcp_schema() { # tools JSON -> MCP tools/list entries
  jq -c 'map({name, description, inputSchema: {
      type: "object",
      properties: (
        [ .positional[] |
          if endswith("*") then {key: rtrimstr("*"), value: {type: "array", items: {type: "string"}}}
          else {key: rtrimstr("?"), value: {type: "string"}} end ]
        + [ .options[] | {key: .name, value: {type: .type}} ]
        | from_entries),
      required: [ .positional[] | select(endswith("?") | not) | rtrimstr("*") ]
    }})'
}

# Prints the argv for a call, one base64 word per line, so any text survives intact.
mcp_argv() { # tools-json tool-name arguments-json
  jq -r --arg name "$2" --argjson a "$3" '
    def text: if type == "string" then . else tostring end;
    (.[] | select(.name == $name)) as $t
    | $t.cli
      + ([ $t.options[] | . as $o | $a[$o.name] as $v
           | if $v == null or $v == false then empty
             elif $o.type == "boolean" then ["--" + $o.name]
             else ["--" + $o.name, ($v | text)] end ] | add // [])
      + (if $t.cli[0] == "ui" and ($t.positional | length) > 0 then ["--"] else [] end)
      + ([ $t.positional[] | rtrimstr("?") as $p | rtrimstr("*") as $k
           | if endswith("*") then ($a[$k] // [] | map(text))
             elif $a[$p] == null then []
             else [$a[$p] | text] end ] | add // [])
    | .[] | @base64' <<<"$1"
}

mcp_reply() { jq -c -n --argjson id "$1" --argjson result "$2" '{jsonrpc: "2.0", id: $id, result: $result}'; }
mcp_error() { jq -c -n --argjson id "$1" --argjson code "$2" --arg m "$3" '{jsonrpc: "2.0", id: $id, error: {code: $code, message: $m}}'; }

mcp_call() { # id tool arguments
  local id=$1 name=$2 arguments=$3 word out err=/dev/null code argv=() content
  if ! jq -e --arg n "$name" 'any(.[]; .name == $n)' <<<"$MCP_TABLE" >/dev/null; then
    mcp_error "$id" -32602 "Unknown tool: $name"; return
  fi
  while IFS= read -r word; do
    argv+=("$(printf '%s' "$word" | /usr/bin/base64 -D)")
  done < <(mcp_argv "$MCP_TABLE" "$name" "$arguments")
  err=$(/usr/bin/mktemp)
  out=$("$SELF" "${argv[@]}" 2>"$err" </dev/null); code=$?
  content=$(jq -n -c --arg t "$out$( [ -s "$err" ] && [ "$code" -ne 0 ] && printf '\n%s' "$(cat "$err")" )" '[{type: "text", text: $t}]')
  rm -f "$err"
  if [ "$name" = screenshot ] && [ "$code" -eq 0 ] && [ -f "$out" ]; then
    content=$(/usr/bin/base64 -i "$out" | tr -d '\n' | jq -R -c --argjson rest "$content" '[{type: "image", mimeType: "image/png", data: .}] + $rest')
  fi
  # A large image goes through a file because it can exceed the argument limit.
  jq -c -n --argjson id "$id" --argjson code "$code" --slurpfile c <(printf '%s' "$content") \
    '{jsonrpc: "2.0", id: $id, result: {content: $c[0], isError: ($code != 0)}}'
}

cmd_mcp() {
  command -v jq >/dev/null || die "jq is required"
  MCP_TABLE=$(mcp_tools_json)
  local list line id method guide
  list=$(mcp_schema <<<"$MCP_TABLE")
  guide="Runs in a headless VM, so the host Mac is not touched. Prefer ui_elements, ui_click and ui_type. Use screenshot and coordinates when an app exposes no accessible element."
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! method=$(jq -r '.method // empty' <<<"$line" 2>/dev/null); then
      mcp_error null -32700 "Parse error"; continue
    fi
    id=$(jq -c '.id // empty' <<<"$line")
    [ -n "$id" ] && [ -n "$method" ] || continue   # a notification or a response
    case "$method" in
      initialize)
        mcp_reply "$id" "$(jq -c --arg v "$VERSION" --arg g "$guide" '{
          protocolVersion: (.params.protocolVersion // "2025-06-18"),
          capabilities: {tools: {listChanged: false}},
          serverInfo: {name: "macvm", version: $v}, instructions: $g}' <<<"$line")" ;;
      ping) mcp_reply "$id" '{}' ;;
      tools/list) mcp_reply "$id" "$(jq -c -n --argjson t "$list" '{tools: $t}')" ;;
      tools/call)
        mcp_call "$id" "$(jq -r '.params.name // ""' <<<"$line")" "$(jq -c '.params.arguments // {}' <<<"$line")" ;;
      *) mcp_error "$id" -32601 "Method not found: $method" ;;
    esac
  done
}
