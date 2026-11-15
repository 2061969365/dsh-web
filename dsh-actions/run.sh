#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_SH="$SCRIPT_DIR/state.sh"

log() { printf '%s run.sh: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
warn() { log "warning: $*"; }
die() { log "error: $*"; exit 1; }

: "${DSH_HOME:?DSH_HOME must be set}"
: "${DSH_WORKSPACE:?DSH_WORKSPACE must be set}"
: "${DSH_SCRATCH:?DSH_SCRATCH must be set}"
: "${RUN_DIR:?RUN_DIR must be set}"
: "${DSH_PUBLIC_HOST:?DSH_PUBLIC_HOST must be set}"
: "${STATE_REPO:?STATE_REPO must be set}"
: "${STATE_REPO_TOKEN:?STATE_REPO_TOKEN must be set}"
: "${CF_TUNNEL_TOKEN:?CF_TUNNEL_TOKEN must be set}"

DSH_PUBLIC_HOST="${DSH_PUBLIC_HOST%/}"
[[ -n "$DSH_PUBLIC_HOST" ]] || die "DSH_PUBLIC_HOST is empty"
[[ "$DSH_PUBLIC_HOST" != *"://"* && "$DSH_PUBLIC_HOST" != */* ]] \
  || die "DSH_PUBLIC_HOST must be a bare hostname, not a URL"

as_uint() {
  local name="$1" raw="$2" min="$3" max="$4" value
  [[ "$raw" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer"
  (( ${#raw} <= 9 )) || die "$name is too large"
  value=$((10#$raw))
  (( value >= min && value <= max )) || die "$name must be between $min and $max"
  printf '%s' "$value"
}

MAX_RUNTIME_MIN="$(as_uint DSH_MAX_RUNTIME_MIN "${DSH_MAX_RUNTIME_MIN:-330}" 1 600)"
CHECKPOINT_BASE_MIN="$(as_uint DSH_CHECKPOINT_MIN "${DSH_CHECKPOINT_MIN:-10}" 1 60)"
CHECKPOINT_LONG_MIN="$(as_uint DSH_CHECKPOINT_LONG_MIN "${DSH_CHECKPOINT_LONG_MIN:-20}" 1 120)"
(( CHECKPOINT_LONG_MIN >= CHECKPOINT_BASE_MIN )) || CHECKPOINT_LONG_MIN="$CHECKPOINT_BASE_MIN"
MIN_FREE_MB="$(as_uint DSH_MIN_FREE_MB "${DSH_MIN_FREE_MB:-5120}" 0 1048576)"
MIN_INODE_PCT="$(as_uint DSH_MIN_INODE_PCT "${DSH_MIN_INODE_PCT:-3}" 1 100)"
TEMP_WARN_MB="$(as_uint DSH_TEMP_WARN_MB "${DSH_TEMP_WARN_MB:-8192}" 0 1048576)"
TEMP_CRIT_FREE_MB="$(as_uint DSH_TEMP_CRIT_FREE_MB "${DSH_TEMP_CRIT_FREE_MB:-6144}" 0 1048576)"
STOP_GRACE_SEC="$(as_uint DSH_STOP_GRACE_SEC "${DSH_STOP_GRACE_SEC:-120}" 1 600)"
CFD_STOP_GRACE_SEC="$(as_uint DSH_CFD_STOP_GRACE_SEC "${DSH_CFD_STOP_GRACE_SEC:-30}" 1 300)"
URL_TIMEOUT_SEC="$(as_uint DSH_URL_TIMEOUT_SEC "${DSH_URL_TIMEOUT_SEC:-300}" 10 1800)"
SUBPROCESS_MAX_AGE_MIN="$(as_uint DSH_SUBPROCESS_MAX_AGE_MIN "${DSH_SUBPROCESS_MAX_AGE_MIN:-60}" 1 1440)"

AUTO_RESTART="${DSH_AUTO_RESTART:-false}"
case "$AUTO_RESTART" in
  true|TRUE|1|yes|YES) AUTO_RESTART=true ;;
  false|FALSE|0|no|NO|'') AUTO_RESTART=false ;;
  *) warn "ignoring invalid DSH_AUTO_RESTART value"; AUTO_RESTART=false ;;
esac

RESTARTS_LEFT="${DSH_RESTARTS_LEFT:-0}"
if [[ ! "$RESTARTS_LEFT" =~ ^[0-9]+$ ]] || (( ${#RESTARTS_LEFT} > 6 )); then
  warn "ignoring invalid DSH_RESTARTS_LEFT value"
  RESTARTS_LEFT=0
else
  RESTARTS_LEFT=$((10#$RESTARTS_LEFT))
fi

readonly DSH_LOG="$RUN_DIR/dsh-web.log"
readonly CFD_LOG="$RUN_DIR/cloudflared.log"
readonly STATE_LOG="$RUN_DIR/state.log"
readonly URL_FILE="$RUN_DIR/url.txt"
readonly AUTO_RESTART_LOG="$RUN_DIR/auto-restart.log"

STARTED_AT="$(date +%s)"
DEADLINE_EPOCH=$(( STARTED_AT + MAX_RUNTIME_MIN * 60 ))
ENDED_AT="$STARTED_AT"

STOP_REQUESTED=0
STOP_REASON=""
NORMAL_DEADLINE=0
EXIT_CODE=""
CLEANUP_DONE=0

DSH_PID=""
CFD_PID=""
DSH_URL=""

CHECKPOINT_EVERY_MIN="$CHECKPOINT_BASE_MIN"
CHECKPOINT_COUNT=0
CHECKPOINT_FAILURES=0
LAST_CHECKPOINT_AT="$STARTED_AT"
LAST_FREE_MB=""
LAST_INODE_FREE_PCT=100
FINAL_SAVE_RC=1
RELEASE_LOCK_RC=1
AUTO_RESTART_RC=""

process_alive() {
  local pid="${1:-}" state
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
  state="${state//[[:space:]]/}"
  [[ -n "$state" && "$state" != Z* ]]
}

terminate_process() {
  local pid="${1:-}" grace="${2:-0}" label="${3:-process}" waited=0
  [[ -n "$pid" ]] || return 0
  if process_alive "$pid"; then
    log "sending SIGTERM to $label (pid $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    while process_alive "$pid" && (( waited < grace )); do
      sleep 1 || true
      waited=$(( waited + 1 ))
    done
    if process_alive "$pid"; then
      warn "$label did not exit within ${grace}s; sending SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
      waited=0
      while process_alive "$pid" && (( waited < 10 )); do
        sleep 1 || true
        waited=$(( waited + 1 ))
      done
    fi
  fi
  wait "$pid" 2>/dev/null || true
}

disk_guard() {
  local target avail_kb free_mb iuse ifree_pct
  for target in / "$DSH_SCRATCH"; do
    avail_kb="$(df -Pk -- "$target" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
      free_mb=$(( avail_kb / 1024 ))
      if [[ -z "$LAST_FREE_MB" ]] || (( free_mb < LAST_FREE_MB )); then
        LAST_FREE_MB="$free_mb"
      fi
      if (( free_mb < MIN_FREE_MB )); then
        warn "low free space on $target: ${free_mb}MB < ${MIN_FREE_MB}MB"
        return 1
      fi
    else
      warn "could not read free space for $target"
    fi
    iuse="$(df -P -i -- "$target" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || true)"
    if [[ "$iuse" =~ ^[0-9]+$ ]] && (( iuse >= 0 && iuse <= 100 )); then
      ifree_pct=$(( 100 - iuse ))
      if (( ifree_pct < LAST_INODE_FREE_PCT )); then
        LAST_INODE_FREE_PCT="$ifree_pct"
      fi
      if (( ifree_pct < MIN_INODE_PCT )); then
        warn "low free inodes on $target: ${ifree_pct}% < ${MIN_INODE_PCT}%"
        return 1
      fi
    fi
  done
  return 0
}

state_call() {
  local limit="${STATE_CALL_TIMEOUT_SEC:-900}" rc=0
  if [[ "${1:-}" == "--timeout" ]]; then
    limit="$2"
    shift 2
  fi
  timeout --signal=TERM --kill-after=30s "$limit" bash "$STATE_SH" "$@" >>"$STATE_LOG" 2>&1 || rc=$?
  return "$rc"
}

state_status_raw_mb() {
  local json="" raw=""
  json="$(timeout 30 bash "$STATE_SH" status 2>>"$STATE_LOG" || true)"
  [[ -n "$json" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    raw="$(printf '%s' "$json" | jq -r '.raw_mb // .snapshot.raw_mb // .last_save.last_raw_mb // .last_save.raw_mb // empty' 2>/dev/null || true)"
  fi
  if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
    raw="$(printf '%s' "$json" | grep -o '"raw_mb"[[:space:]]*:[[:space:]]*[0-9][0-9]*' | head -n 1 | grep -o '[0-9][0-9]*$' || true)"
  fi
  if [[ ! "$raw" =~ ^[0-9]+$ ]]; then
    raw="$(printf '%s' "$json" | grep -o '"last_raw_mb"[[:space:]]*:[[:space:]]*[0-9][0-9]*' | head -n 1 | grep -o '[0-9][0-9]*$' || true)"
  fi
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$raw"
}

estimate_state_mb() {
  local home_mb="" work_mb=""
  local -a home_excludes=(
    --exclude=spill --exclude=cache --exclude=logs --exclude=node_modules
    --exclude=.plugin-manager --exclude=.dsh-market --exclude=compatibility.json
    --exclude='session_projcache*' --exclude=dsh-context --exclude=session-purge-trash
    --exclude='*.bak*' --exclude='*.tmp' --exclude='*.tmpdir' --exclude='*.imported'
  )
  local -a work_excludes=(
    --exclude=.git --exclude=node_modules --exclude=.venv --exclude=venv
    --exclude=__pycache__ --exclude=.pytest_cache --exclude=.mypy_cache
    --exclude=.ruff_cache --exclude=target --exclude=dist --exclude=build
    --exclude=.next --exclude=.cache --exclude=.pnpm-store
    --exclude='*.tmp' --exclude='*.tmpdir' --exclude='*.log'
  )
  home_mb="$(timeout 120 du -sm "${home_excludes[@]}" -- "$DSH_HOME" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  work_mb="$(timeout 120 du -sm "${work_excludes[@]}" -- "$DSH_WORKSPACE" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  [[ "$home_mb" =~ ^[0-9]+$ ]] || home_mb=0
  [[ "$work_mb" =~ ^[0-9]+$ ]] || work_mb=0
  printf '%s' "$(( home_mb + work_mb ))"
}

prune_subprocess_spill() {
  [[ -d "$TMPDIR" ]] || return 0
  log "pruning dsh-subprocess-* older than ${SUBPROCESS_MAX_AGE_MIN} min"
  find "$TMPDIR" -mindepth 1 -maxdepth 1 -name 'dsh-subprocess-*' \
    -mmin +"$SUBPROCESS_MAX_AGE_MIN" -exec rm -rf -- {} + 2>/dev/null || true
}

cleanup_tmp_scratch() {
  local tmp="${TMPDIR:-}" tmp_real home_real scratch_real
  local -a match
  [[ -n "$tmp" && -d "$tmp" ]] || return 0
  tmp_real="$(realpath -m -- "$tmp" 2>/dev/null || printf '%s' "$tmp")"
  home_real="$(realpath -m -- "$DSH_HOME" 2>/dev/null || printf '%s' "$DSH_HOME")"
  scratch_real="$(realpath -m -- "$DSH_SCRATCH" 2>/dev/null || printf '%s' "$DSH_SCRATCH")"
  if [[ "$tmp_real" == "$home_real" || "$tmp_real" == "$home_real"/* ]]; then
    warn "refusing to clean TMPDIR because it is inside DSH_HOME"
    return 0
  fi
  if [[ "$tmp_real" == "$scratch_real" ]]; then
    warn "refusing to clean TMPDIR because it is the scratch root"
    return 0
  fi
  if [[ "$tmp_real" == "$scratch_real"/* ]]; then
    match=( -name 'dsh-*' )
  else
    match=( \( -name 'dsh-subprocess-*' -o -name 'dsh-workspace-changes-*' -o -name 'dsh-ssh-*' -o -name 'dsh-spill*' \) )
  fi
  log "cleaning DSH scratch entries under TMPDIR"
  find "$tmp" -mindepth 1 -maxdepth 1 "${match[@]}" -exec rm -rf -- {} + 2>/dev/null || true
}

publish_url() {
  local url="$1" rc=0
  printf '%s\n' "$url" > "$URL_FILE"
  chmod 600 -- "$URL_FILE"
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf '::add-mask::%s\n' "$url"
  fi
  log "publishing the dsh URL to the private state branch"
  state_call publish-url || rc=$?
  if (( rc != 0 )); then
    warn "state.sh publish-url failed (rc=$rc); see $STATE_LOG"
    return "$rc"
  fi
  return 0
}

wait_for_url() {
  local waited=0 line url rc=0
  while (( waited < URL_TIMEOUT_SEC )); do
    (( STOP_REQUESTED == 0 )) || return 2
    if ! process_alive "$DSH_PID"; then
      wait "$DSH_PID" 2>/dev/null || rc=$?
      DSH_PID=""
      warn "dsh exited before printing its URL line (rc=$rc); see $DSH_LOG"
      return 1
    fi
    line="$(grep -m1 -E '^dsh web: https?://' "$DSH_LOG" 2>/dev/null || true)"
    if [[ -n "$line" ]]; then
      url="${line#dsh web: }"
      url="${url#"${url%%[![:space:]]*}"}"
      url="${url%%[[:space:]]*}"
      if [[ ! "$url" =~ ^https?://[^[:space:]]+$ ]]; then
        warn "could not parse the dsh URL line"
        return 1
      fi
      if [[ "$url" != "https://$DSH_PUBLIC_HOST/"* ]]; then
        warn "the dsh URL does not match the configured public host"
        return 1
      fi
      DSH_URL="$url"
      return 0
    fi
    sleep 1 || true
    waited=$(( waited + 1 ))
  done
  warn "timed out after ${URL_TIMEOUT_SEC}s waiting for the dsh URL line"
  return 1
}

start_cloudflared() {
  local rc=0
  log "starting cloudflared"
  env -u STATE_REPO_TOKEN -u CF_TUNNEL_TOKEN -u DEEPSEEK_API_KEY -u DSH_NOTIFY_WEBHOOK \
    -u GH_TOKEN -u GITHUB_TOKEN TUNNEL_TOKEN="$CF_TUNNEL_TOKEN" cloudflared tunnel \
    --no-autoupdate --protocol http2 --grace-period 5s run \
    >>"$CFD_LOG" 2>&1 &
  CFD_PID=$!
  sleep 3 || true
  if ! process_alive "$CFD_PID"; then
    wait "$CFD_PID" 2>/dev/null || rc=$?
    CFD_PID=""
    warn "cloudflared exited during startup (rc=$rc); see $CFD_LOG"
    return 1
  fi
  return 0
}

start_dsh() {
  log "starting dsh web"
  (
    cd -- "$DSH_WORKSPACE"
    exec env -u STATE_REPO_TOKEN -u CF_TUNNEL_TOKEN -u GH_TOKEN -u GITHUB_TOKEN -u DSH_NOTIFY_WEBHOOK \
      dsh web --host 127.0.0.1 --port 3080 --no-open \
        --public-url "https://$DSH_PUBLIC_HOST/" \
        --trusted-host "$DSH_PUBLIC_HOST"
  ) >>"$DSH_LOG" 2>&1 &
  DSH_PID=$!
}

checkpoint() {
  local rc=0 raw_mb="" temp_mb=""
  LAST_CHECKPOINT_AT="$(date +%s)"
  log "checkpoint: saving state (interval ${CHECKPOINT_EVERY_MIN} min)"
  state_call save || rc=$?
  if (( rc == 0 )); then
    CHECKPOINT_COUNT=$(( CHECKPOINT_COUNT + 1 ))
    CHECKPOINT_FAILURES=0
  elif (( rc == 2 )); then
    warn "state.sh save reported a hard budget violation (exit 2)"
    STOP_REASON="state-budget"
    EXIT_CODE=1
    return 1
  elif (( rc == 3 )); then
    warn "state.sh save reported a lock conflict (exit 3)"
    STOP_REASON="state-lock-lost"
    EXIT_CODE=1
    return 1
  elif (( rc == 4 )); then
    warn "state.sh save reported a snapshot/restore failure (exit 4)"
    STOP_REASON="state-restore-failed"
    EXIT_CODE=1
    return 1
  elif (( rc == 5 )); then
    warn "state.sh save reported a gitleaks finding (exit 5)"
    STOP_REASON="state-gitleaks"
    EXIT_CODE=1
    return 1
  elif (( rc == 6 )); then
    warn "state.sh save reported a validation or disk guard failure (exit 6)"
    STOP_REASON="state-validation-failed"
    EXIT_CODE=1
    return 1
  else
    CHECKPOINT_FAILURES=$(( CHECKPOINT_FAILURES + 1 ))
    warn "state.sh save failed (rc=$rc, consecutive=${CHECKPOINT_FAILURES}); see $STATE_LOG"
    if (( CHECKPOINT_FAILURES >= 3 )); then
      STOP_REASON="state-save-failed"
      EXIT_CODE=1
      return 1
    fi
  fi
  raw_mb="$(state_status_raw_mb || true)"
  if [[ ! "$raw_mb" =~ ^[0-9]+$ ]]; then
    raw_mb="$(estimate_state_mb)"
  fi
  if [[ "$raw_mb" =~ ^[0-9]+$ ]] && (( raw_mb > 2048 )); then
    CHECKPOINT_EVERY_MIN="$CHECKPOINT_LONG_MIN"
  else
    CHECKPOINT_EVERY_MIN="$CHECKPOINT_BASE_MIN"
  fi
  temp_mb="$(timeout 120 du -sm -- "$TMPDIR" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  [[ "$temp_mb" =~ ^[0-9]+$ ]] || temp_mb=0
  log "state raw size ${raw_mb}MB; temp usage ${temp_mb}MB; next checkpoint in ${CHECKPOINT_EVERY_MIN} min"
  if (( temp_mb > TEMP_WARN_MB )) || { [[ -n "$LAST_FREE_MB" ]] && (( LAST_FREE_MB < TEMP_CRIT_FREE_MB )); }; then
    warn "temp usage is ${temp_mb}MB and free space is ${LAST_FREE_MB:-unknown}MB; pruning subprocess spill"
    prune_subprocess_spill
  fi
  return 0
}

run_loop() {
  local now disk_at=0 rc=0
  while true; do
    if (( STOP_REQUESTED == 1 )); then
      STOP_REASON="${STOP_REASON:-signal}"
      EXIT_CODE=0
      return 0
    fi
    if timeout 20 bash "$STATE_SH" should-stop >/dev/null 2>&1; then
      log "stop requested through the state stop variable"
      STOP_REASON="stop-variable"
      EXIT_CODE=0
      return 0
    fi
    if ! process_alive "$DSH_PID"; then
      wait "$DSH_PID" 2>/dev/null || rc=$?
      DSH_PID=""
      warn "dsh exited unexpectedly (rc=$rc); see $DSH_LOG"
      STOP_REASON="dsh-exited"
      EXIT_CODE=1
      return 0
    fi
    if ! process_alive "$CFD_PID"; then
      wait "$CFD_PID" 2>/dev/null || rc=$?
      CFD_PID=""
      warn "cloudflared exited unexpectedly (rc=$rc); see $CFD_LOG"
      STOP_REASON="cloudflared-exited"
      EXIT_CODE=1
      return 0
    fi
    now="$(date +%s)"
    if (( now >= DEADLINE_EPOCH )); then
      log "runtime deadline reached (${MAX_RUNTIME_MIN} min)"
      NORMAL_DEADLINE=1
      STOP_REASON="deadline"
      EXIT_CODE=0
      return 0
    fi
    if (( now - disk_at >= 30 )); then
      disk_at="$now"
      if ! disk_guard; then
        STOP_REASON="low-disk"
        EXIT_CODE=0
        return 0
      fi
    fi
    if (( now >= LAST_CHECKPOINT_AT + CHECKPOINT_EVERY_MIN * 60 )); then
      if ! checkpoint; then
        return 0
      fi
    fi
    sleep 10 || true
  done
}

maybe_auto_restart() {
  local next_left rc=0
  (( NORMAL_DEADLINE == 1 )) || return 0
  [[ "$AUTO_RESTART" == "true" ]] || return 0
  (( RESTARTS_LEFT > 0 )) || return 0
  if (( FINAL_SAVE_RC != 0 || RELEASE_LOCK_RC != 0 )); then
    warn "auto-restart skipped because the final save or lock release failed"
    return 0
  fi
  if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_REF_NAME:-}" || -z "${GITHUB_TOKEN:-}" ]]; then
    warn "auto-restart skipped because the GitHub environment is incomplete"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || { warn "auto-restart skipped because gh is not installed"; return 0; }
  next_left=$(( RESTARTS_LEFT - 1 ))
  GH_TOKEN="$GITHUB_TOKEN" gh workflow run dsh-web.yml \
    --repo "$GITHUB_REPOSITORY" \
    --ref "$GITHUB_REF_NAME" \
    -f auto_restart=true \
    -f restarts_left="$next_left" \
    -f max_runtime_minutes="$MAX_RUNTIME_MIN" \
    -f checkpoint_minutes="$CHECKPOINT_BASE_MIN" \
    >>"$AUTO_RESTART_LOG" 2>&1 || rc=$?
  AUTO_RESTART_RC="$rc"
  if (( rc == 0 )); then
    log "auto-restart dispatched (restarts_left=${next_left})"
  else
    warn "auto-restart dispatch failed (rc=$rc); see $AUTO_RESTART_LOG"
  fi
  return 0
}

write_summary() {
  local summary="${GITHUB_STEP_SUMMARY:-}" duration_min result lock_text
  [[ -n "$summary" ]] || return 0
  duration_min=$(( (ENDED_AT - STARTED_AT) / 60 ))
  result="failed"
  case "$STOP_REASON" in
    deadline) result="completed (deadline)" ;;
    stop-variable) result="stopped (requested)" ;;
    low-disk) result="stopped (low disk)" ;;
    signal) result="stopped (signal)" ;;
    completed) result="completed" ;;
  esac
  if (( RELEASE_LOCK_RC == 0 )); then lock_text="yes"; else lock_text="no"; fi
  {
    echo "## dsh-web supervisor"
    echo
    echo "| field | value |"
    echo "| --- | --- |"
    echo "| run id | ${GITHUB_RUN_ID:-local} |"
    echo "| result | ${result} |"
    echo "| stop reason | ${STOP_REASON:-unknown} |"
    echo "| runtime | ${duration_min} min |"
    echo "| checkpoints | ${CHECKPOINT_COUNT} |"
    echo "| final save | rc=${FINAL_SAVE_RC:-unknown} |"
    echo "| lock released | ${lock_text} |"
    echo "| free disk | ${LAST_FREE_MB:-unknown} MB |"
    echo "| free inodes | ${LAST_INODE_FREE_PCT:-unknown}% |"
    echo "| private URL | published to the private state repo at \`runtime/url.txt\` (not printed here) |"
    if [[ -n "$AUTO_RESTART_RC" ]]; then
      echo "| auto-restart | attempt rc=${AUTO_RESTART_RC} |"
    fi
  } >> "$summary" 2>/dev/null || true
  return 0
}

cleanup() {
  local trigger_rc="${1:-0}"
  trap '' TERM INT
  if [[ -z "$STOP_REASON" ]]; then
    if (( trigger_rc != 0 )); then
      STOP_REASON="error"
      EXIT_CODE="$trigger_rc"
    else
      STOP_REASON="completed"
    fi
  fi
  [[ -n "$EXIT_CODE" ]] || EXIT_CODE="$trigger_rc"
  ENDED_AT="$(date +%s)"
  log "stopping (reason: ${STOP_REASON})"
  terminate_process "${DSH_PID:-}" "$STOP_GRACE_SEC" "dsh"
  DSH_PID=""
  terminate_process "${CFD_PID:-}" "$CFD_STOP_GRACE_SEC" "cloudflared"
  CFD_PID=""
  cleanup_tmp_scratch
  if [[ -f "$STATE_SH" ]]; then
    log "final state save"
    FINAL_SAVE_RC=0
    state_call --timeout 420 save --final || FINAL_SAVE_RC=$?
    if (( FINAL_SAVE_RC != 0 )); then
      warn "final state save failed (rc=$FINAL_SAVE_RC); see $STATE_LOG"
    fi
    log "releasing the state lock"
    RELEASE_LOCK_RC=0
    state_call --timeout 60 release-lock || RELEASE_LOCK_RC=$?
    if (( RELEASE_LOCK_RC != 0 )); then
      warn "release-lock failed (rc=$RELEASE_LOCK_RC); see $STATE_LOG"
    fi
  else
    FINAL_SAVE_RC=1
    RELEASE_LOCK_RC=1
  fi
  if (( FINAL_SAVE_RC != 0 || RELEASE_LOCK_RC != 0 )) && (( EXIT_CODE == 0 )); then
    EXIT_CODE=1
  fi
  maybe_auto_restart
  write_summary
  log "supervisor finished (rc=$EXIT_CODE)"
}

on_exit() {
  local rc=$?
  trap - EXIT
  trap '' TERM INT
  set +e
  if (( CLEANUP_DONE == 0 )); then
    CLEANUP_DONE=1
    [[ -n "$EXIT_CODE" ]] || EXIT_CODE="$rc"
    cleanup "$rc"
  fi
  exit "${EXIT_CODE:-$rc}"
}

trap on_exit EXIT
trap 'STOP_REQUESTED=1; STOP_REASON="${STOP_REASON:-signal}"' TERM INT

main() {
  [[ -f "$STATE_SH" ]] || die "state.sh not found at $STATE_SH"
  command -v bash >/dev/null 2>&1 || die "bash is not available"
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared is not on PATH"
  command -v dsh >/dev/null 2>&1 || die "dsh is not on PATH"
  command -v df >/dev/null 2>&1 || die "df is not available"
  [[ -d "$DSH_HOME" ]] || die "DSH_HOME does not exist"
  [[ -d "$DSH_WORKSPACE" ]] || die "DSH_WORKSPACE does not exist"

  mkdir -p -- "$RUN_DIR"
  chmod 700 -- "$RUN_DIR" 2>/dev/null || true
  : > "$DSH_LOG"
  : > "$CFD_LOG"
  : > "$STATE_LOG"
  : > "$AUTO_RESTART_LOG"
  chmod 600 -- "$DSH_LOG" "$CFD_LOG" "$STATE_LOG" "$AUTO_RESTART_LOG" 2>/dev/null || true

  if [[ -z "${TMPDIR:-}" ]]; then
    TMPDIR="$DSH_SCRATCH/dsh-tmp"
  fi
  mkdir -p -- "$TMPDIR"
  chmod 700 -- "$TMPDIR" 2>/dev/null || true
  export TMPDIR
  export TMP="${TMP:-$TMPDIR}"
  export TEMP="${TEMP:-$TMPDIR}"

  prune_subprocess_spill

  if ! start_cloudflared; then
    STOP_REASON="cloudflared-startup"
    EXIT_CODE=1
    return 0
  fi
  unset CF_TUNNEL_TOKEN

  start_dsh
  local url_rc=0
  wait_for_url || url_rc=$?
  if (( url_rc == 2 )); then
    STOP_REASON="signal"
    EXIT_CODE=0
    return 0
  elif (( url_rc != 0 )); then
    STOP_REASON="startup-failed"
    EXIT_CODE=1
    return 0
  fi
  if ! publish_url "$DSH_URL"; then
    STOP_REASON="publish-failed"
    EXIT_CODE=1
    return 0
  fi
  log "dsh web is up; supervisor loop started"
  run_loop
}

main
exit 0
