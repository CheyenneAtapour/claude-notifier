#!/bin/bash
# Claude Notifier hook: keeps one file per Claude session in sessions/, which
# the Claude Notifier app reads. Reads the hook's JSON from stdin.
#   prompt  you sent a prompt: it is working on it (records the task)
#   done    it finished its reply (red in the menu bar)
#   input   it is blocked on you: a permission or a question (green)
#   resume  it is working again after you answered
#   end     the session closed
notifier="$HOME/.claude/notifier"
dir="$notifier/sessions"
mkdir -p "$dir"
input=$(cat)
id=$(jq -r '.session_id // empty' <<<"$input")
[ -n "$id" ] || exit 0
file="$dir/$id.json"
now=$(date +%s)

# The terminal device of the nearest ancestor that has one: the Claude session's
# tab, which the app brings into focus.
tty_of_session() {
  local pid=$$ t
  while [ "$pid" -gt 1 ]; do
    t=$(ps -o tty= -p "$pid" | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "??" ]; then echo "/dev/$t"; return; fi
    pid=$(ps -o ppid= -p "$pid" | tr -d ' ')
  done
}

state() { jq -r '.state // empty' "$file" 2>/dev/null; }

# Merges the session's current place and the JSON object $1 into its file.
update() {
  local cwd branch old
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
  old=$(cat "$file" 2>/dev/null || echo '{}')
  jq -n --argjson old "$old" --argjson new "$1" --arg cwd "$cwd" --arg branch "$branch" \
    --arg tty "$(tty_of_session)" --argjson time "$now" \
    '$old + {cwd: $cwd, branch: $branch, tty: $tty, time: $time} + $new' >"$file.tmp" && mv "$file.tmp" "$file"
}

case "$1" in
prompt)
  update "$(jq -c --argjson started "$now" '{state: "working", task: ((.prompt // "")[0:500]), started: $started, message: ""}' <<<"$input")"
  ;;
done)
  # How long the prompt took, for the dashboard's rough estimates.
  started=$(jq -r '.started // empty' "$file" 2>/dev/null)
  if [ -n "$started" ] && [ "$(state)" != "done" ]; then
    echo "{\"seconds\":$((now - started)),\"time\":$now}" >>"$notifier/history.jsonl"
  fi
  update '{"state": "done", "message": ""}'
  ;;
input)
  type=$(jq -r '.notification_type // empty' <<<"$input")
  message=$(jq -r '.message // empty' <<<"$input")
  # The idle reminder follows a finished reply, which is already marked done.
  if [ "$type" = "idle_prompt" ] || [[ "$message" == *"waiting for your input"* ]]; then exit 0; fi
  [ "$(jq -r '.tool_name // empty' <<<"$input")" = "AskUserQuestion" ] && message="has a question for you"
  update "$(jq -n --arg message "${message:-needs you}" '{state: "input", message: $message}')"
  ;;
resume)
  if [ ! -f "$file" ]; then
    # A session already working when the notifier started: take its task, your
    # last typed prompt, from its transcript.
    transcript=$(jq -r '.transcript_path // empty' <<<"$input")
    last=$(grep '"type":"user"' "$transcript" 2>/dev/null | grep -v '"tool_result"' | tail -n 20 |
      jq -cs '[.[] | select((.message.content | type) == "string" and (.isMeta | not))] | last // {}
        | {task: ((.message.content // "")[0:500]),
           started: (.timestamp | if . then sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 else null end)}' 2>/dev/null)
    [ -n "$last" ] || last='{}'
    update "$(jq -c '{state: "working", message: ""} + .' <<<"$last")"
  elif [ "$(state)" = "input" ]; then
    update '{"state": "working", "message": ""}'
  fi
  ;;
end)
  rm -f "$file"
  ;;
esac
exit 0
