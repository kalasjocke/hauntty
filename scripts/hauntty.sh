#!/bin/sh
# A Claude Code hook that tells Hauntty what each session is doing. Hook it to
# these events in ~/.claude/settings.json, all with this script as the
# command: UserPromptSubmit, PostToolUse, PermissionRequest, Notification,
# Stop, StopFailure and SessionEnd.
#
# It keeps one line per session in $TMPDIR/hauntty/claude-sessions, with five
# tab-separated fields:
#
# 1. The session id.
# 2. The state, with the state names of the OSC 7501 program status protocol:
#    - working: you sent a prompt (UserPromptSubmit), or a tool finished
#      (PostToolUse), which ends blocked once you answer a prompt.
#    - blocked: Claude waits on a permission prompt or a question
#      (PermissionRequest, Notification).
#    - done: a turn finished (Stop).
#    - error: a turn ended on an API error (StopFailure).
#    The line is removed when the session ends (SessionEnd).
# 3. The session's name. Claude Code titles a pane that shows a session with
#    its name, which is how Hauntty finds background sessions.
# 4. For a session running in a tmux pane, the pane, like "default:%12": the
#    tmux socket name and the pane id. Empty for a background session.
# 5. That pane's title when the hook ran, since a session running in a pane
#    is not always titled with its name.
#
# Hooks of several sessions run at once, and Hauntty removes a done, blocked
# or error line once you look at the tab. Each of them takes the lock in
# .claude-sessions.lock while it rewrites the file, and renames a new file
# into place, so a reader never sees half a file. Claude Code runs no hook when
# you interrupt a turn, so working stays until the next prompt or the end of
# the session.

input=$(cat)
field() { printf '%s' "$input" | jq -r "$1"; }

case $(field .hook_event_name) in
  UserPromptSubmit | PostToolUse) state=working ;;
  PermissionRequest) state=blocked ;;
  Stop) state=done ;;
  StopFailure) state=error ;;
  SessionEnd) state= ;;
  Notification)
    # Prompts, questions and dialogs, in this session or an agent it tracks,
    # wait on you. idle_prompt fires a minute after Stop and must not turn done
    # into blocked. agent_completed is covered by Stop, and the other types,
    # like auth_success and push_notification, need no action.
    case $(field '.notification_type // ""') in
      permission_prompt | worker_permission_prompt | elicitation_dialog | \
        elicitation_url_dialog | agent_needs_input | "") state=blocked ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

sid=$(field '.session_id // ""')
[ -n "$sid" ] || exit 0

# Tabs and newlines would break the line into fields and lines.
clean() { printf '%s' "$1" | tr '\t\n' '  '; }

line=
if [ -n "$state" ]; then
  name=$(jq -r --arg s "$sid" 'select(.sessionId == $s) | .name // empty' \
    "$HOME"/.claude/sessions/*.json 2>/dev/null | head -1)
  pane=
  title=
  if [ -n "$TMUX_PANE" ] && [ -n "$TMUX" ]; then
    # $TMUX is the socket path, the server pid and the session, like
    # "/private/tmp/tmux-501/default,123,0".
    socket=${TMUX%%,*}
    pane=${socket##*/}:$TMUX_PANE
    title=$(tmux display -p -t "$TMUX_PANE" '#{pane_title}' 2>/dev/null)
  fi
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$(clean "$sid")" "$state" \
    "$(clean "$name")" "$pane" "$(clean "$title")")
fi

dir=${TMPDIR:-/tmp}/hauntty
file=$dir/claude-sessions
mkdir -p "$dir"

# Hold the lock until the script exits. lockf locks the shell's descriptor 9,
# with flock(2) like Hauntty.
exec 9>"$dir/.claude-sessions.lock"
lockf -s -t 5 9 || exit 0

{
  [ -f "$file" ] && awk -F '\t' -v id="$(clean "$sid")" '$1 != id' "$file"
  [ -n "$line" ] && printf '%s\n' "$line"
} >"$dir/.claude-sessions.$$"
mv "$dir/.claude-sessions.$$" "$file"
exit 0
