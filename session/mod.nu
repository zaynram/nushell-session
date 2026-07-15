# Manage Zellij sessions: inspect, boot, switch, delete, and open editor panes.

def session-name [context: string]: nothing -> list {
  let names: list<string> = try { zellij list-sessions | to text | lines }
    | parse '{name} {_}' | get name
    | append $env.ZELLIJ_AUTO_SESSION?
    | compact | ansi strip | str trim | flatten | uniq
  let query: string = $context | split row ' ' | where $it !~ `-` | last
  if ($query | is-empty) { $names } else { $names | where $it =~ $'^($query)' }
}

# Get the age and status of a Zellij session(s).
#
# If no name is given, information for all sessions will be returned as a table.
export def info [
  name?: string@session-name # The name of the target session
  --short (-s) # Return a list of only session names
]: nothing -> oneof<list<string>, record<name: string, age: duration, status: string>, table<name: string, age: duration, status: string>> {

  let data: table = try { zellij list-sessions | to text }
    | lines
    | parse '{name} [Created {age} ago]{status}'
    | ansi strip name age status
    | update name { str trim }

  if $short { return $data.name }

  let info: table = $data
    | update status { str trim | parse '({state} {_}' | get --optional 0.state | default alive | str lowercase }
    | update age {
      parse --regex `(\d\w+)` | get capture0 | par-each {
        let split: list = $in | split chars | split list --split before { $in !~ \d }
        let n: int = $split | first | str join | into int
        let unit: string = $split | skip 1 | flatten | str join
        match $unit {
          s => { $n }
          m => { $n * 60 }
          h => { $n * 3600 }
          $u if $u =~ day => { $n * 3600 * 24 }
          $u if $u =~ month => { $n * 3600 * 24 * 30.4375 }
        }
      } | math sum | append sec | str join | into duration
    }

  if $name == null { $info } else { $info | where name == $name | first }
}

# Kill and delete a Zellij session, or all Zellij sessions.
export def del [
  name?: string@session-name # The name of the target session
  --all # Target all Zellij sessions
]: nothing -> nothing {
  match {n: $name a: $all} {
    {n: null a: false} => { error make --unspanned 'name is required without `--all`' }
    {a: true} => { for act in [kill delete] { try { zellij $'($act)-all-sessions' } } }
    {n: $n} => { for act in [kill delete] { try { zellij $'($act)-session' $n } } }
  }
}

# Switch to another Zellij session.
export def --wrapped swap [
  name: string@session-name # The name of the session to switch to
  ...rest: string # Additional arguments to pass with the action
]: nothing -> nothing {
  zellij action switch-session $name ...$rest
}

# Perform an action(s) on a Zellij session.
export alias act = zellij action

# Invoke `zellij run` and automatically close the created pane.
export alias exec = zellij run --close-on-exit

def layout-name []: nothing -> list {
  cd ($env.XDG_CONFIG_HOME | path join zellij)
  glob --no-dir --no-symlink layouts/*.kdl | path parse | get stem
}

# Save a `zellij run` terminal id to `$env.LAST_TERMINAL_ID`.
export def --env --wrapped run [
  ...rest: string # The commandline to run with `zellij run`
  --args: list<string> = [] # Arguments to pass to `zellij run` (not the commandline itself).
]: nothing -> string {
  let text: string = zellij run ...$args -- ...$rest | to text
  let id: int = try {
    $text | parse `terminal_{n}` | first | get n | into int
  } catch {
    error make 'unable to parse terminal_id'
  }
  load-env {LAST_TERMINAL_ID: $id}
  return $text
}
# Enter a Zellij session, creating it if it does not exist.
export def --env boot [
  name?: string@session-name # The target session name (can be set with `$env.ZELLIJ_AUTO_SESSION`)
  --set-default (-s) # Save the session name as the default
  --attach (-a) = true # Attach to the session if it already exists
  --layout (-l): string@layout-name # Set the layout of the session
]: nothing -> nothing {
  if $name != null and $set_default { $env.ZELLIJ_AUTO_SESSION = $name }
  let session: string = $name | default $env.ZELLIJ_AUTO_SESSION?
  let args: list<string> = if $attach {
    if $layout != null { [options --default-layout $layout] }
    | prepend [attach --create ...(append $session | compact)]
  } else if $session != null {
    if $layout != null { [--new-session-with-layout $layout] }
    | prepend [--session $session]
  } | default { if $layout != null { [--new-session-with-layout $layout] } else { [] } }
  try { zellij ...$args }
}

def is-editor-pane []: record<id: int, title: string> -> bool {
  match $in {
    {is_suppressed: true} => { return false }
    {title: editor} => { return true }
    {title: $t} if $t =~ Editing: => { return true }
    {pane_command: $c} if $c =~ $env.config.buffer_editor => { return true }
    _ => { return false }
  }
}

# Open a file in an editor pane.
export def --env --wrapped edit [
  ...rest: string # Arguments to pass through to the `edit` invocation
]: oneof<nothing, path, record<name: path>> -> nothing {
  let args: list = match ($in | describe) {
    string => $in
    _ => { default [] | get --optional name }
  } | prepend $rest | compact | uniq
  let pane: record = zellij action list-panes --json
    | from json
    | where ($it | is-editor-pane) | last

  if $pane.id? != null {
    zellij action focus-pane-id $pane.id
    zellij edit --in-place ...$args out+err>|
  } else {
    zellij edit ...$args out+err>|
  } | return
}
