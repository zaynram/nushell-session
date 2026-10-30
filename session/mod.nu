# Manage Zellij sessions: inspect, boot, switch, delete, and open editor panes.

# nu-lint-ignore-file: unused_helper_functions

# ——— imports ——————————————————————————————————————————————————————————————————

use std/util null-device

# ——— completions ——————————————————————————————————————————————————————————————

def _session_names []: nothing -> list {
  ^zellij list-sessions --short --no-formatting | lines | str trim
}

def _layout_names []: nothing -> list {
  cd ($env.XDG_CONFIG_HOME | path join zellij)
  glob --no-dir --no-symlink layouts/*.kdl | path parse | get stem
}

def --wrapped _proxy-completion [...rest: string]: nothing -> list {
  $'zellij ($rest | str join (char sp)) ' | commandline complete
}

def _session_actions []: nothing -> list { _proxy-completion action }
def _session_run_options []: nothing -> list { _proxy-completion run }
def _session_attach []: nothing -> list { _proxy-completion attach }
def _session_edit []: nothing -> list { _proxy-completion edit }

# ——— definitions ——————————————————————————————————————————————————————————————

# Get the age and status of a Zellij session(s).
#
# If no name is given, information for all sessions will be returned as a table.
export def list [
  regex?: string@_session_names # Only include sessions with names matching this pattern
  --short (-s) # Return a list of only session names
  --active (-a) # Only include sessions that have not exited
  --exited (-e) # Only include sessions that have already exited
]: nothing -> oneof<list<string>, record<name: string, age: duration, status: string>, table<name: string, age: duration, status: string>> {
  ^zellij list-sessions --no-formatting err> (null-device)
  | lines
  | parse '{name} [Created {age} ago]{status}'
  | str trim name
  | if $short {
    get $.name
  } else {
    update $.status { str trim | parse '({state} {_}' | get $.0?.state | default active | str lowercase }
    | where (
      # match names only when regex provided
      ($regex == null or $it.name =~ $regex) and
      # filter status by options with everything as the default
      $active == $exited or
      (not $active or $it.status == active) and
      (not $exited or $it.status == exited)
    ) | update $.age {
      parse --regex `(\d\w+)` | get $.capture0 | par-each {
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
  }
}

# Kill and delete a Zellij session, or all Zellij sessions.
export def down [
  name?: string@_session_names # The name of the target session
  --all # Target all Zellij sessions
]: nothing -> nothing {
  match {n: $name a: $all} {
    {n: null a: false} => { error make --unspanned 'name is required without `--all`' }
    {a: true} => ( for act in [kill delete] { ^zellij $'($act)-all-sessions' err> (null-device) })
    {n: $n} => ( for act in [kill delete] { ^zellij $'($act)-session' $n err> (null-device) })
  }
}

# Switch to another Zellij session.
export def --wrapped switch [
  name: string@_session_names # The name of the session to switch to
  ...rest: string # Additional arguments to pass with the action
]: nothing -> nothing { ^zellij action switch-session $name ...$rest }

# Perform an action on a Zellij session.
export def --wrapped manage [
  name?: string@_session_names # The name of the session to switch to
  ...rest: string@_session_actions # Additional arguments to pass with the action
]: nothing -> nothing {
  $name | match ($in | describe) {
    nothing if $env has ZELLIJ => {|| ^zellij action ...$rest }
    nothing if $env has ZELLIJ_SESSION_NAME => {|| ^zellij --session=($env.ZELLIJ_SESSION_NAME) action ...$rest }
    string => {|| ^zellij --session=($in) action ...$rest }
    nothing => { error make --unspanned 'no session name was given and none could be detected' }
  } | do --capture-errors $in
}

# Run a command with in a Zellij session.
#
# Arguments for the command invocation can be passed as pipeline input
# or included in the command string.
export def --wrapped exec [
  command: string
  # Command to run with Zellij; if prefixed with an ampersand, the `run` invocation will be spawned as a job
  ...rest: string@_session_run_options
  # Additional arguments to pass as `zellij run` options
]: oneof<nothing, list<string>> -> oneof<nothing, string, record> {
  let args: list<string> = default ($command | split row (char sp) | skip)
  let name: string = $command | split row (char sp) | first | str trim --left --char='&'
  {|| ^zellij run ...$rest -- $name ...$args } | if $command starts-with & {
    let spawn: closure;
    let id: int = job spawn --description=$'session_exec_(random chars --length=8)' $spawn
    job list | where id == $id | into record
  } else {
    do --capture-errors $in
  }
}

# Enter a Zellij session, creating it if it does not exist.
export def --env enter [
  name?: string@_session_names # The target session name
  --attach (-a) = true # Attach to the session if it already exists
  --layout (-l): string@_layout_names # Set the layout of the session
  ...rest: string@_session_attach # Additional arguments to pass through to `zellij attach`
]: nothing -> nothing {
  let session: oneof<nothing, string> = $name | default $env.ZELLIJ_AUTO_SESSION?
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
  target?: path # Open this file or directory in the editor
  --help (-h) # Show the help message for this function
  --workspace (-w): directory # Set this as the root working directory
  --close-pane (-c) # Close the replaced pane instead of suspending it
  ...rest: string@_session_edit # Arguments to pass through to the `edit` invocation
]: oneof<nothing, path, record<name: path>> -> oneof<nothing, string> {
  let root: path = $workspace | default { pwd }
  let args: list = match ($in | describe | split words | first) {
    string => $in
    record => { get --optional name }
    _ if $target != null => $target
    _ => { error make --unspanned 'no path was provided' }
  } | prepend $rest
    | if $close_pane {
      append [--close-replace-pane]
    } else { }
    | compact | uniq

  zellij action list-panes --json
  | from json
  | where ($it | is-editor-pane)
  | last
  | match $in {
    null => { ^zellij edit ...$args err> (null-device) }
    {id: $n} => {
      ^zellij action focus-pane-id $n
      ^zellij edit --cwd $root --in-place ...$args err> (null-device)
    }
  } | ignore
  return
}
