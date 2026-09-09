#!/usr/bin/env bash
# ===========================================================================
# Mail agent.
#  (A) INBOUND : unseen mail -> Claude writes a reply -> DRAFT (default) or
#                SEND (allowlisted senders only, send mode).
#  (B) OUTBOUND: queue.txt   -> Claude composes a new email -> DRAFT (default)
#                or SEND (send mode) -- ONLY to allowlisted recipients.
#
# Claude only ever returns TEXT. This script decides whether/where to send.
# Outbound goes only to an address that YOU put in queue.txt AND that is on
# allow.txt, so untrusted inbox content can never choose a new recipient.
# Commands below are matched to Himalaya's `message add/send/reply/read`.
# ===========================================================================
set -uo pipefail          # NOTE: no -e; we log-and-continue on tool errors.
cd "$(dirname "$0")"

# Make sure claude / himalaya / jq are found no matter which shell (or the
# Windows Task Scheduler) launches this script.
export PATH="$PATH:$HOME/.local/bin:$HOME/scoop/shims"

# ---- config ---------------------------------------------------------------
MODE="draft"                          # "draft" = never send (SAFE DEFAULT).
                                      # "send"  = send to allowlisted, draft rest.
# From: address for composed emails. Auto-derived from the first account in your
# Himalaya config, or set MAIL_AGENT_FROM to override. Must match the sending account.
MY_ADDR="${MAIL_AGENT_FROM:-$(grep -m1 -E 'sasl.plain.username|^email' "$HOME/.config/himalaya/config.toml" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')}"
RATE_MAX=5                            # hard cap on auto-sends per run.
# Free/public mail providers we never auto-trust by domain match.
PUBLIC_DOMAINS="gmail.com googlemail.com outlook.com hotmail.com live.com yahoo.com yahoo.co.uk icloud.com me.com aol.com proton.me protonmail.com gmx.com gmx.net web.de mail.com"
# ---------------------------------------------------------------------------

unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY || true  # clear stale/inherited creds FIRST
source ./.env                       # a token takes effect ONLY if actually written in .env

SEEN_DB="./handled.txt"; ALLOWLIST="./allow.txt"
QUEUE="./queue.txt";     QUEUE_DONE="./queue-handled.txt"; LOG="./agent.log"
touch "$SEEN_DB" "$ALLOWLIST" "$QUEUE" "$QUEUE_DONE"
SYSTEM="$(cat ./reply-system.md)"
COMPOSE_SYSTEM="$(cat ./compose-system.md 2>/dev/null || true)"
sent_count=0
log(){ printf '%s %s\n' "$(date -Is)" "$1" | tee -a "$LOG"; }

# --- The ONE place the Himalaya commands live (verified via --help). ---------
do_draft(){  himalaya message reply "$1" --body "$2" --save drafts; }  # reply -> Drafts
do_send(){   himalaya message reply "$1" --body "$2" --send;        }  # reply -> sent
do_compose_draft(){ himalaya message add --mailbox drafts --flag draft; } # stdin -> Drafts
do_compose_send(){  himalaya message send;                              } # stdin -> sent

# Which reply prompt to use for an inbound sender: match their domain against
# queue.txt and return the @type of the section it sits in (default hospitality).
queue_type_for(){  # $1 = lowercase sender domain
  awk -v dom="$1" 'BEGIN{t="hospitality"}
    /^[[:space:]]*@type[[:space:]]/ { t=$2; next }
    /^[[:space:]]*#/ { next }
    /\|/ { r=$0; sub(/\|.*/,"",r); gsub(/[ \t]/,"",r); d=r; sub(/.*@/,"",d);
           if (dom!="" && tolower(d)==dom) { print t; found=1; exit } }
    END { if(!found) print "hospitality" }' "$QUEUE"
}

# ===========================================================================
# (B) OUTBOUND QUEUE
# ===========================================================================
process_queue(){
  local qtype="hospitality"
  while IFS= read -r line || [ -n "$line" ]; do
    # "@type <name>" header selects which compose-*.md prompt the following
    # lines use (until the next @type). Default is hospitality.
    case "$line" in
      '@type '*|'@type	'*)
        qtype=$(printf '%s' "$line" | sed 's/^@type[[:space:]]*//' | tr 'A-Z' 'a-z' | tr -d '[:space:]')
        log "queue: switching to type '$qtype'"; continue ;;
    esac
    case "$line" in ''|\#*) continue ;; esac
    key=$(printf '%s' "$line" | md5sum | cut -d' ' -f1)
    grep -qxF "$key" "$QUEUE_DONE" && continue

    to=$(printf '%s'   "$line" | cut -d'|' -f1  | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')
    instr=$(printf '%s' "$line" | cut -d'|' -f2- | sed 's/^[[:space:]]*//')
    [ -z "$to" ] && { echo "$key" >> "$QUEUE_DONE"; continue; }

    if ! grep -v '^#' "$ALLOWLIST" | grep -qiF "$to"; then
      log "queue: recipient NOT allowlisted, skipped $to"; echo "$key" >> "$QUEUE_DONE"; continue
    fi

    case "$qtype" in
      conferencing) PROMPT_FILE="compose-conferencing.md" ;;
      *)            PROMPT_FILE="compose-system.md" ;;   # hospitality / default
    esac
    [ -f "$PROMPT_FILE" ] || PROMPT_FILE="compose-system.md"

    out=$(printf '%s' "$(cat "$PROMPT_FILE")

--- TASK ---
Recipient: $to
Instruction: $instr" | claude -p --model sonnet --allowedTools "" 2>/dev/null || true)

    subj=$(printf '%s' "$out" | sed -n 's/^SUBJECT:[[:space:]]*//p' | head -1)
    body=$(printf '%s' "$out" | sed '1,/^---[[:space:]]*$/d')
    if [ -z "$subj" ] || [ -z "$body" ]; then
      log "queue: compose blank/failed for $to (will retry next run)"; continue
    fi
    echo "$key" >> "$QUEUE_DONE"    # mark handled before send attempt

    raw=$(printf 'From: %s\nTo: %s\nSubject: %s\n\n%s\n' "$MY_ADDR" "$to" "$subj" "$body")
    if [ "$MODE" = "send" ] && [ "$sent_count" -lt "$RATE_MAX" ]; then
      if printf '%s' "$raw" | do_compose_send; then
        sent_count=$((sent_count+1)); log "QUEUE SENT [$qtype] to $to"
      else log "queue SEND FAILED for $to"; fi
    else
      if printf '%s' "$raw" | do_compose_draft; then
        log "queue drafted [$qtype] (mode=$MODE) $to"
      else log "queue DRAFT FAILED for $to"; fi
    fi
  done < "$QUEUE"
}

# ===========================================================================
# (A) INBOUND   (JSON: {"envelopes":[{id,message-id,flags[],from[].email,...}]})
# ===========================================================================
process_inbox(){
  while read -r env; do
    id=$(jq -r '.id' <<<"$env")
    msgid=$(jq -r '.["message-id"] // .id' <<<"$env")
    FROM=$(jq -r '.from[0].email // .from[0].name // "unknown"' <<<"$env")
    SUBJECT=$(jq -r '.subject // ""' <<<"$env")

    grep -qxF "$msgid" "$SEEN_DB" && continue
    echo "$msgid" >> "$SEEN_DB"     # mark handled FIRST so a crash can't re-loop

    case "$FROM" in
      *no-reply*|*noreply*|*mailer-daemon*|*bounce*|*notifications*|*donotreply*|*billetterie*|*newsletter*)
        log "filtered (bulk) $FROM"; continue ;;
    esac

    # Forwarded/passed-on colleague: a NEW sender at a venue domain we already
    # contacted -> add to allowlist so Gavin can auto-reply in send mode.
    # Never auto-trust public/free mail domains.
    FROMDOM=$(printf '%s' "$FROM" | sed 's/.*@//' | tr 'A-Z' 'a-z')
    if [ "$FROMDOM" != "$FROM" ]; then
      case " $PUBLIC_DOMAINS " in
        *" $FROMDOM "*) : ;;
        *)
          if ! grep -v '^#' "$ALLOWLIST" | grep -qiF "$FROM" \
             && grep -v '^#' "$ALLOWLIST" | grep -qiF "@$FROMDOM"; then
            echo "$FROM" >> "$ALLOWLIST"
            log "auto-allowed forwarded contact $FROM (trusted domain @$FROMDOM)"
          fi ;;
      esac
    fi

    body=$(himalaya message read "$id" 2>/dev/null || echo "")

    # Route the reply by SUBJECT first (survives cross-domain replies, e.g. a
    # venue replying from a different domain than the one we emailed), then fall
    # back to the sender's domain in the queue, then hospitality.
    subjl=$(printf '%s' "$SUBJECT" | tr 'A-Z' 'a-z')
    case "$subjl" in
      *conferenc*|*delegate*|*"meeting room"*|*"room hire"*|*"day delegate"*) rt="conferencing" ;;
      *hospitalit*)                                                            rt="hospitality" ;;
      *) rt=$(queue_type_for "$FROMDOM") ;;
    esac
    case "$rt" in
      conferencing) SYS_FILE="reply-conferencing.md" ;;
      *)            SYS_FILE="reply-system.md" ;;
    esac
    [ -f "$SYS_FILE" ] || SYS_FILE="reply-system.md"
    SYS="$(cat "$SYS_FILE")"

    reply=$(printf '%s' "$SYS

--- EMAIL ---
From: $FROM
Subject: $SUBJECT
<UNTRUSTED>
$body
</UNTRUSTED>" | claude -p --model sonnet --allowedTools "" 2>/dev/null || true)

    if [ "$reply" = "SKIP" ] || [ -z "$reply" ]; then
      log "skipped (model declined) $FROM"; continue
    fi

    if [ "$MODE" != "send" ]; then
      if do_draft "$id" "$reply" >/dev/null 2>&1; then log "drafted [$rt] (draft mode) $FROM"
      else log "DRAFT FAILED $FROM"; fi
      continue
    fi

    if grep -v '^#' "$ALLOWLIST" | grep -qiF "$FROM"; then
      if [ "$sent_count" -ge "$RATE_MAX" ]; then
        do_draft "$id" "$reply" >/dev/null 2>&1 && log "rate cap hit; drafted $FROM"; continue
      fi
      if do_send "$id" "$reply" >/dev/null 2>&1; then
        sent_count=$((sent_count+1)); log "SENT reply to $FROM"
      else log "SEND FAILED $FROM"; fi
    else
      do_draft "$id" "$reply" >/dev/null 2>&1 && log "drafted (not on allowlist) $FROM" || log "DRAFT FAILED $FROM"
    fi
  done < <(himalaya envelope list --json | jq -c '.envelopes[] | select((.flags // []) | index("Seen") | not)')
}

log "run start (mode=$MODE)"
process_queue
process_inbox
log "run end (sent=$sent_count)"
