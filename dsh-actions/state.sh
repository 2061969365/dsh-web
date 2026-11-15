#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

DSH_HOME=${DSH_HOME:-/home/runner/dsh-home}
DSH_WORKSPACE=${DSH_WORKSPACE:-/home/runner/dsh-work}
DSH_SCRATCH=${DSH_SCRATCH:-/mnt}
STATE_CLONE=${STATE_CLONE:-${DSH_SCRATCH%/}/dsh-state}
RUN_DIR=${RUN_DIR:-${DSH_SCRATCH%/}/run}
STATE_REPO=${STATE_REPO:-}
STATE_REPO_TOKEN=${STATE_REPO_TOKEN:-}
GITHUB_RUN_ID=${GITHUB_RUN_ID:-}
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-}
DSH_VERSION=${DSH_VERSION:-}
STATE_BUDGET_MB=${STATE_BUDGET_MB:-5120}
STATE_WARN_MB=${STATE_WARN_MB:-3072}
STATE_ASSET_PART_MB=${STATE_ASSET_PART_MB:-1900}
STATE_KEEP_SNAPSHOTS=${STATE_KEEP_SNAPSHOTS:-2}
STATE_MIN_FREE_MB=${STATE_MIN_FREE_MB:-${DSH_MIN_FREE_MB:-5120}}
STATE_LOCK_STALE_MIN=${STATE_LOCK_STALE_MIN:-45}
DSH_PERSIST_CREDENTIALS=${DSH_PERSIST_CREDENTIALS:-false}
DSH_KEEP_STAGING=${DSH_KEEP_STAGING:-false}
DSH_SKIP_GITLEAKS=${DSH_SKIP_GITLEAKS:-false}
SESSION_ARCHIVE_ENABLED=${SESSION_ARCHIVE_ENABLED:-false}
SESSION_HOT_MAX=${SESSION_HOT_MAX:-50}
SESSION_HOT_DAYS=${SESSION_HOT_DAYS:-30}
SESSION_ARCHIVE_MIN_AGE_SEC=${SESSION_ARCHIVE_MIN_AGE_SEC:-60}

STATE_TAG=dsh-state
EXCLUDES=$SCRIPT_DIR/sync-excludes.txt
STAGE_DIR=$RUN_DIR/state
DL_DIR=$RUN_DIR/state-download
ASKPASS=$RUN_DIR/git-askpass.sh
GITLEAKS_CONFIG=$RUN_DIR/gitleaks.toml
RUNTIME_DIR=$STATE_CLONE/runtime
META_FILE=$RUNTIME_DIR/meta.json
LOCK_FILE=$RUNTIME_DIR/lock.json
STATE_FILE=$RUNTIME_DIR/state.json
PREV_FILE=$RUNTIME_DIR/state.prev.json
URL_FILE=$RUNTIME_DIR/url.txt
CLEAN_STAGING=false
CLEAN_DOWNLOADS=false
RESTORED_FROM=none
RESTORED_ID=
REMOTE_SHA=
HOST_NAME=$(uname -n 2>/dev/null || printf 'unknown')
GITLEAKS_EXIT_CODE=5

usage() {
  cat <<'USAGE'
Usage: state.sh <command> [args]

Commands:
  init                 clone control branch, verify private repo/lock, restore snapshot, write lock
  publish-url [url]    store runtime/url.txt (0600); with no url read $RUN_DIR/url.txt
  save [--final]       stage home/work, scan, tar+split+upload, update pointers, commit and clean
  should-stop          exit 0 when DSH_STOP equals GITHUB_RUN_ID or "all"
  release-lock         remove runtime/lock.json and commit
  status               print compact JSON status

Exit codes:
  0 success / stop requested      1 config, auth, network or generic failure
  2 hard raw-state budget         3 lock held by another run
  4 snapshot/restore failure      5 gitleaks findings
  6 validation or disk guard      64 usage

Environment:
  DSH_HOME DSH_WORKSPACE STATE_REPO STATE_REPO_TOKEN STATE_CLONE RUN_DIR
  GITHUB_RUN_ID GITHUB_REPOSITORY STATE_BUDGET_MB STATE_WARN_MB
  STATE_ASSET_PART_MB STATE_KEEP_SNAPSHOTS STATE_MIN_FREE_MB
  optional: DSH_VERSION DSH_PERSIST_CREDENTIALS DSH_KEEP_STAGING
            SESSION_ARCHIVE_ENABLED SESSION_HOT_MAX SESSION_HOT_DAYS
            SESSION_ARCHIVE_MIN_AGE_SEC
            DSH_SKIP_GITLEAKS STATE_LOCK_STALE_MIN
USAGE
}

log() { printf '[state %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
warn() { printf '[state %s] WARNING: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { local code=$1; shift; printf '[state %s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit "$code"; }

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$DSH_KEEP_STAGING" != true ]; then
    if [ "$CLEAN_STAGING" = true ]; then
      [ -n "${STAGE_DIR:-}" ] && rm -rf -- "$STAGE_DIR" 2>/dev/null || true
    fi
    if [ "$CLEAN_STAGING" = true ] || [ "$CLEAN_DOWNLOADS" = true ]; then
      [ -n "${DL_DIR:-}" ] && rm -rf -- "$DL_DIR" 2>/dev/null || true
    fi
  fi
  if [ -n "${STATE_CLONE:-}" ] && [ -d "$STATE_CLONE/.git" ]; then
    rm -f -- "$STATE_CLONE/runtime/url.txt.tmp" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
ts_compact() { date -u +%Y%m%dT%H%M%SZ; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die 6 "required command not found: $1"
}

require_env() {
  local name=$1
  [ -n "${!name:-}" ] || die 1 "missing required environment variable: $name"
}

validate_state_repo() {
  case $STATE_REPO in
    *[!A-Za-z0-9._/-]*|/*|*/|*//*) die 1 "STATE_REPO must be owner/name" ;;
  esac
  case $STATE_REPO in
    */*) ;;
    *) die 1 "STATE_REPO must be owner/name" ;;
  esac
  case ${STATE_REPO#*/} in
    */*) die 1 "STATE_REPO must be owner/name" ;;
  esac
}

validate_numbers() {
  local var val
  for var in STATE_BUDGET_MB STATE_WARN_MB STATE_ASSET_PART_MB STATE_KEEP_SNAPSHOTS STATE_MIN_FREE_MB STATE_LOCK_STALE_MIN; do
    val=${!var}
    case $val in
      ''|*[!0-9]*) die 1 "$var must be a positive integer" ;;
    esac
    [ "$val" -gt 0 ] || die 1 "$var must be a positive integer"
  done
  [ "$STATE_ASSET_PART_MB" -le 1900 ] || die 1 "STATE_ASSET_PART_MB must be <= 1900 (GitHub asset limit)"
  [ "$STATE_MIN_FREE_MB" -ge 1024 ] || die 1 "STATE_MIN_FREE_MB must be >= 1024"
  [ "$STATE_KEEP_SNAPSHOTS" -ge 1 ] || die 1 "STATE_KEEP_SNAPSHOTS must be >= 1"
  case $SESSION_ARCHIVE_ENABLED in
    true|false) ;;
    *) die 1 "SESSION_ARCHIVE_ENABLED must be true or false" ;;
  esac
  for var in SESSION_HOT_MAX SESSION_HOT_DAYS SESSION_ARCHIVE_MIN_AGE_SEC; do
    val=${!var}
    case $val in
      ''|*[!0-9]*) die 1 "$var must be a positive integer" ;;
    esac
    [ "$val" -gt 0 ] || die 1 "$var must be a positive integer"
  done
}

require_repo_env() {
  require_env STATE_REPO
  require_env STATE_REPO_TOKEN
  require_env GITHUB_RUN_ID
  validate_state_repo
  validate_numbers
}

gh_state() {
  GH_TOKEN="$STATE_REPO_TOKEN" GH_PROMPT_DISABLED=1 gh "$@"
}

git_state() {
  GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 git -C "$STATE_CLONE" -c credential.helper= "$@"
}

remote_url() { printf 'https://github.com/%s.git' "$STATE_REPO"; }

write_askpass() {
  mkdir -p -- "$RUN_DIR" || die 1 "cannot create RUN_DIR: $RUN_DIR"
  chmod 700 -- "$RUN_DIR" 2>/dev/null || true
  cat > "$ASKPASS" <<'ASKPASS_EOF'
#!/bin/sh
case "${1:-}" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *) printf '%s\n' "${STATE_REPO_TOKEN:-}" ;;
esac
ASKPASS_EOF
  chmod 700 -- "$ASKPASS" || die 1 "cannot write GIT_ASKPASS helper"
}

free_mb_of() {
  local d=$1 v
  [ -d "$d" ] || mkdir -p -- "$d" 2>/dev/null || true
  v=$(df -Pm -- "$d" 2>/dev/null | awk 'NR==2 {print $4}') || v=0
  case $v in
    ''|*[!0-9]*) v=0 ;;
  esac
  printf '%s' "$v"
}

pointer_valid() {
  local f=$1 id parts
  [ -f "$f" ] || return 1
  id=$(jq -r '.id // empty' "$f" 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  parts=$(jq -r '.parts // 0' "$f" 2>/dev/null) || return 1
  case $parts in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$parts" -gt 0 ] || return 1
  jq -e '.trees.home.parts | type == "array" and length > 0' "$f" >/dev/null 2>&1 || return 1
  jq -e '.trees.work.parts | type == "array" and length > 0' "$f" >/dev/null 2>&1 || return 1
  return 0
}

path_contains() {
  case $2 in
    "$1"/*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_writable_dir() {
  local p=$1 r
  case $p in
    /*) ;;
    *) die 6 "path must be absolute: $p" ;;
  esac
  while [ "${p%/}" != "$p" ] && [ "$p" != / ]; do p=${p%/}; done
  if [ -z "$p" ] || [ "$p" = / ]; then die 6 "refusing to use / as DSH_HOME/DSH_WORKSPACE"; fi
  mkdir -p -- "$p" || die 6 "cannot create directory: $p"
  if [ ! -d "$p" ] || [ ! -w "$p" ]; then die 6 "not a writable directory: $p"; fi
  r=$(readlink -f -- "$p") || die 6 "cannot resolve path: $p"
  if [ -z "$r" ] || [ "$r" = / ]; then die 6 "invalid resolved path: $p"; fi
  printf '%s' "$r"
}

validate_workspace_paths() {
  DSH_HOME=$(resolve_writable_dir "$DSH_HOME")
  DSH_WORKSPACE=$(resolve_writable_dir "$DSH_WORKSPACE")
  [ "$DSH_HOME" != "$DSH_WORKSPACE" ] || die 6 "DSH_HOME and DSH_WORKSPACE must differ"
  if path_contains "$DSH_HOME" "$DSH_WORKSPACE"; then die 6 "DSH_WORKSPACE must not be inside DSH_HOME"; fi
  if path_contains "$DSH_WORKSPACE" "$DSH_HOME"; then die 6 "DSH_HOME must not be inside DSH_WORKSPACE"; fi
  local sc rd
  sc=$(readlink -m -- "$STATE_CLONE") || die 6 "cannot resolve STATE_CLONE"
  rd=$(readlink -m -- "$RUN_DIR") || die 6 "cannot resolve RUN_DIR"
  case $sc in /*) ;; *) die 6 "STATE_CLONE must be absolute" ;; esac
  case $rd in /*) ;; *) die 6 "RUN_DIR must be absolute" ;; esac
  [ "$sc" != / ] || die 6 "refusing to use / as STATE_CLONE"
  [ "$rd" != / ] || die 6 "refusing to use / as RUN_DIR"
  [ "$sc" != "$rd" ] || die 6 "STATE_CLONE and RUN_DIR must differ"
  if path_contains "$sc" "$rd"; then die 6 "RUN_DIR must not be inside STATE_CLONE"; fi
  if path_contains "$rd" "$sc"; then die 6 "STATE_CLONE must not be inside RUN_DIR"; fi
  local p t
  for p in "$sc" "$rd"; do
    for t in "$DSH_HOME" "$DSH_WORKSPACE"; do
      [ "$p" != "$t" ] || die 6 "$p must differ from state target $t"
      if path_contains "$t" "$p"; then die 6 "$p must not be inside $t"; fi
      if path_contains "$p" "$t"; then die 6 "$t must not be inside $p"; fi
    done
  done
}

ensure_clone() {
  mkdir -p -- "$(dirname -- "$STATE_CLONE")" || die 6 "cannot create STATE_CLONE parent"
  if [ -e "$STATE_CLONE" ] && [ ! -d "$STATE_CLONE/.git" ]; then
    if [ -d "$STATE_CLONE" ] && [ -z "$(ls -A -- "$STATE_CLONE" 2>/dev/null || true)" ]; then
      rmdir -- "$STATE_CLONE" || die 6 "cannot prepare empty STATE_CLONE"
    else
      die 6 "STATE_CLONE exists but is not a git repository: $STATE_CLONE"
    fi
  fi
  if [ ! -d "$STATE_CLONE/.git" ]; then
    git init -q "$STATE_CLONE" || die 1 "cannot init state clone"
  fi
  chmod 700 -- "$STATE_CLONE" 2>/dev/null || true
  write_askpass
  git_state config user.name "dsh-state" >/dev/null || die 1 "cannot configure state clone"
  git_state config user.email "dsh-state@users.noreply.github.com" >/dev/null || die 1 "cannot configure state clone"
  git_state config core.autocrlf false >/dev/null || true
  local url
  url=$(remote_url)
  if git_state remote get-url origin >/dev/null 2>&1; then
    git_state remote set-url origin "$url" >/dev/null || die 1 "cannot set state remote"
  else
    git_state remote add origin "$url" >/dev/null || die 1 "cannot add state remote"
  fi
}

remote_state_sha() {
  REMOTE_SHA=
  local out rc=0
  out=$(git_state ls-remote --exit-code --heads origin refs/heads/state 2>/dev/null) || rc=$?
  case $rc in
    0) REMOTE_SHA=${out%%[[:space:]]*} ;;
    2) REMOTE_SHA= ;;
    *) die 1 "cannot query state branch on $STATE_REPO (git ls-remote exit $rc)" ;;
  esac
}

write_control_skeleton() {
  mkdir -p -- "$RUNTIME_DIR" || die 1 "cannot create runtime directory"
  printf '%s\n' '* -text' '*.zst binary' > "$STATE_CLONE/.gitattributes" || die 1 "cannot write .gitattributes"
  cat > "$STATE_CLONE/README.md" <<'README_EOF'
# dsh-web private state

Control branch for the dsh-web GitHub Actions runner. Snapshot archives live as private
release assets under the `dsh-state` tag. Do not edit while a run is active.
README_EOF
  chmod 600 -- "$STATE_CLONE/.gitattributes" "$STATE_CLONE/README.md" 2>/dev/null || true
}

checkout_control() {
  remote_state_sha
  if [ -n "$REMOTE_SHA" ]; then
    git_state fetch -q --depth 1 origin state || die 1 "failed to fetch state branch"
    git_state checkout -q -f -B state FETCH_HEAD || die 1 "failed to checkout state branch"
  else
    if git_state rev-parse --verify -q HEAD >/dev/null 2>&1; then
      git_state checkout -q -f -B state || die 1 "failed to switch to state branch"
    else
      git_state symbolic-ref HEAD refs/heads/state || die 1 "failed to create state branch"
    fi
  fi
  write_control_skeleton
}

check_private_repo() {
  local private
  private=$(gh_state repo view "$STATE_REPO" --json isPrivate --jq '.isPrivate' 2>/dev/null) || die 1 "cannot read state repo metadata; check STATE_REPO_TOKEN"
  [ "$private" = true ] || die 6 "state repo $STATE_REPO is not private; refusing to store state"
}

tracked_control_bytes() {
  local total
  total=$(cd "$STATE_CLONE" && git ls-files -z | xargs -0 -r stat -c %s -- 2>/dev/null | awk '{s+=$1} END {printf "%d", s+0}')
  case $total in
    ''|*[!0-9]*) total=0 ;;
  esac
  printf '%s' "$total"
}

commit_control() {
  local msg=$1 expected bytes
  remote_state_sha
  expected=$REMOTE_SHA
  git_state add -A || die 1 "git add failed"
  if git_state diff --cached --quiet; then
    if [ -n "$expected" ]; then
      log "control branch unchanged"
      return 0
    fi
    if ! git_state rev-parse --verify -q HEAD >/dev/null 2>&1; then
      return 0
    fi
  else
    bytes=$(tracked_control_bytes)
    if [ "$bytes" -gt $((10 * 1024 * 1024)) ]; then
      die 6 "control branch tracked files exceed 10MB (${bytes} bytes)"
    fi
    if git_state rev-parse --verify -q HEAD >/dev/null 2>&1; then
      git_state commit -q --amend -m "$msg" || die 1 "git commit failed"
    else
      git_state commit -q -m "$msg" || die 1 "git commit failed"
    fi
  fi
  local i new_expected
  for i in 1 2 3; do
    if [ -n "$expected" ]; then
      if git_state push -q --force-with-lease="state:$expected" origin HEAD:refs/heads/state; then
        return 0
      fi
    else
      if git_state push -q origin HEAD:refs/heads/state; then
        return 0
      fi
    fi
    warn "control branch push attempt $i failed"
    sleep $((i * 2))
    if git_state fetch -q --depth 1 origin state; then
      new_expected=$(git_state rev-parse FETCH_HEAD 2>/dev/null || true)
      if [ -n "$new_expected" ] && [ "$new_expected" != "$expected" ]; then
        git_state reset -q --soft FETCH_HEAD || die 1 "cannot rebase onto refreshed control branch"
        if ! git_state diff --cached --quiet; then
          git_state commit -q -m "$msg" || die 1 "git commit failed"
        fi
        expected=$new_expected
        log "control branch advanced; rebuilt commit on $expected"
      fi
    fi
  done
  die 1 "failed to push control branch"
}

lock_field() {
  if [ -f "$LOCK_FILE" ]; then
    jq -r "$1 // empty" "$LOCK_FILE" 2>/dev/null || true
  fi
}

lock_is_ours() {
  local rid
  rid=$(lock_field .run_id)
  [ -n "$GITHUB_RUN_ID" ] && [ "$rid" = "$GITHUB_RUN_ID" ]
}

lock_age_minutes() {
  local hb epoch now
  hb=$(lock_field .heartbeat)
  if [ -z "$hb" ]; then
    printf '%s' 999999
    return 0
  fi
  epoch=$(date -u -d "$hb" +%s 2>/dev/null) || epoch=0
  now=$(now_epoch)
  if [ "$epoch" -le 0 ]; then
    printf '%s' 999999
  else
    printf '%s' $(((now - epoch) / 60))
  fi
}

check_lock_or_takeover() {
  [ -f "$LOCK_FILE" ] || return 0
  if lock_is_ours; then
    log "state lock already owned by run $GITHUB_RUN_ID"
    return 0
  fi
  if ! jq -e . "$LOCK_FILE" >/dev/null 2>&1; then
    warn "state lock is invalid; taking over"
    return 0
  fi
  local rid host hb age
  rid=$(lock_field .run_id)
  host=$(lock_field .host)
  hb=$(lock_field .heartbeat)
  age=$(lock_age_minutes)
  if [ "$age" -ge "$STATE_LOCK_STALE_MIN" ]; then
    warn "taking over stale lock (run=${rid:-unknown} host=${host:-unknown} heartbeat=${hb:-unknown} age=${age}m)"
    return 0
  fi
  die 3 "state lock held by run ${rid:-unknown} on ${host:-unknown} (heartbeat ${hb:-unknown}, age ${age}m); refusing concurrent startup"
}

write_lock() {
  local started now
  started=$(lock_field .started)
  if ! lock_is_ours || [ -z "$started" ]; then
    started=$(now_iso)
  fi
  now=$(now_iso)
  jq -cn --arg run_id "$GITHUB_RUN_ID" --arg host "$HOST_NAME" --arg started "$started" --arg heartbeat "$now" \
    '{run_id:$run_id,host:$host,started:$started,heartbeat:$heartbeat}' > "$LOCK_FILE.tmp" || die 1 "cannot write lock"
  chmod 600 -- "$LOCK_FILE.tmp" 2>/dev/null || true
  mv -f -- "$LOCK_FILE.tmp" "$LOCK_FILE" || die 1 "cannot install lock"
}

refresh_lock_heartbeat() {
  [ -f "$LOCK_FILE" ] || return 0
  if ! lock_is_ours; then
    return 0
  fi
  local now tmp
  now=$(now_iso)
  tmp=$LOCK_FILE.tmp
  if ! jq --arg now "$now" '.heartbeat=$now' "$LOCK_FILE" > "$tmp" 2>/dev/null; then
    warn "cannot refresh lock heartbeat"
    rm -f -- "$tmp" 2>/dev/null || true
    return 0
  fi
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$LOCK_FILE" 2>/dev/null || warn "cannot install lock heartbeat"
}

meta_base() {
  if [ -f "$META_FILE" ] && jq -e . "$META_FILE" >/dev/null 2>&1; then
    cat -- "$META_FILE"
  else
    printf '{}'
  fi
}

write_json_file() {
  local file=$1 json=$2 tmp=$1.tmp
  printf '%s\n' "$json" > "$tmp" || die 1 "cannot write $file"
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file" || die 1 "cannot replace $file"
}

update_meta_init() {
  local base json now free_s free_r
  base=$(meta_base)
  now=$(now_iso)
  free_s=$(free_mb_of "$RUN_DIR")
  free_r=$(free_mb_of /)
  json=$(jq -c \
    --arg run_id "$GITHUB_RUN_ID" \
    --arg repo "$GITHUB_REPOSITORY" \
    --arg version "$DSH_VERSION" \
    --arg host "$HOST_NAME" \
    --arg now "$now" \
    --argjson sfree "$free_s" \
    --argjson rfree "$free_r" \
    --arg source "$RESTORED_FROM" \
    --arg sid "$RESTORED_ID" \
    '. as $o
     | $o + {
         run_id:$run_id,
         repo:(if $repo=="" then null else $repo end),
         version:(if $version=="" then null else $version end),
         host:$host,
         updated_at:$now,
         disk:{scratch_free_mb:$sfree,root_free_mb:$rfree},
         restore:{source:$source,snapshot:(if $sid=="" then null else $sid end),at:$now}
       }
     | .started_at = ($o.started_at // $now)
     | .checkpoint = ($o.checkpoint // {count:0})
     | .url_published = ($o.url_published // false)' <<<"$base") || die 1 "cannot build init metadata"
  write_json_file "$META_FILE" "$json"
}

update_meta_publish() {
  local base json now free_s free_r sha=$1
  base=$(meta_base)
  now=$(now_iso)
  free_s=$(free_mb_of "$RUN_DIR")
  free_r=$(free_mb_of /)
  json=$(jq -c \
    --arg run_id "$GITHUB_RUN_ID" \
    --arg host "$HOST_NAME" \
    --arg now "$now" \
    --arg sha "$sha" \
    --argjson sfree "$free_s" \
    --argjson rfree "$free_r" \
    '. as $o
     | $o + {
         run_id:($o.run_id // $run_id),
         host:$host,
         updated_at:$now,
         published_at:$now,
         url_published:true,
         url_sha256:$sha,
         disk:{scratch_free_mb:$sfree,root_free_mb:$rfree}
       }' <<<"$base") || die 1 "cannot build publish metadata"
  write_json_file "$META_FILE" "$json"
}

update_meta_save() {
  local sid=$1 raw=$2 abytes=$3 parts=$4 final=$5 over_warn=$6 duration=$7 count=$8
  local archived_count=$9 archived_bytes=${10}
  local base json now free_s free_r
  base=$(meta_base)
  now=$(now_iso)
  free_s=$(free_mb_of "$RUN_DIR")
  free_r=$(free_mb_of /)
  json=$(jq -c \
    --arg run_id "$GITHUB_RUN_ID" \
    --arg host "$HOST_NAME" \
    --arg now "$now" \
    --arg sid "$sid" \
    --argjson raw "$raw" \
    --argjson abytes "$abytes" \
    --argjson parts "$parts" \
    --argjson final "$final" \
    --argjson over_warn "$over_warn" \
    --argjson duration "$duration" \
    --argjson count "$count" \
    --argjson archived_count "$archived_count" \
    --argjson archived_bytes "$archived_bytes" \
    --argjson sfree "$free_s" \
    --argjson rfree "$free_r" \
    '. as $o
     | $o + {
         run_id:($o.run_id // $run_id),
         host:$host,
         updated_at:$now,
         disk:{scratch_free_mb:$sfree,root_free_mb:$rfree},
         state:{id:$sid,raw_mb:$raw,archive_bytes:$abytes,parts:$parts,over_warn:$over_warn,
                archived:{sessions:$archived_count,bytes:$archived_bytes}},
         checkpoint:{count:$count,last_at:$now,last_final:$final,last_duration_s:$duration,last_raw_mb:$raw,last_snapshot:$sid,
                     archived:{sessions:$archived_count,bytes:$archived_bytes}}
       }' <<<"$base") || die 1 "cannot build save metadata"
  write_json_file "$META_FILE" "$json"
}

update_meta_release() {
  local base json now
  base=$(meta_base)
  now=$(now_iso)
  json=$(jq -c \
    --arg run_id "$GITHUB_RUN_ID" \
    --arg host "$HOST_NAME" \
    --arg now "$now" \
    '. as $o
     | $o + {
         run_id:($o.run_id // $run_id),
         host:$host,
         updated_at:$now,
         released_at:$now
       }' <<<"$base") || die 1 "cannot build release metadata"
  write_json_file "$META_FILE" "$json"
}

require_control_clone() {
  [ -d "$STATE_CLONE/.git" ] || die 1 "state clone not found at $STATE_CLONE; run state.sh init first"
  mkdir -p -- "$RUNTIME_DIR" || die 1 "cannot create runtime directory"
  write_askpass
  local url branch
  url=$(remote_url)
  if git_state remote get-url origin >/dev/null 2>&1; then
    git_state remote set-url origin "$url" >/dev/null || die 1 "cannot set state remote"
  else
    git_state remote add origin "$url" >/dev/null || die 1 "cannot add state remote"
  fi
  git_state config user.name "dsh-state" >/dev/null || die 1 "cannot configure state clone"
  git_state config user.email "dsh-state@users.noreply.github.com" >/dev/null || die 1 "cannot configure state clone"
  branch=$(git_state rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ "$branch" = state ] || die 1 "state clone is not on the state branch; run state.sh init first"
}

require_lock_ours() {
  [ -f "$LOCK_FILE" ] || die 3 "no state lock present; run state.sh init first"
  if ! lock_is_ours; then
    local rid
    rid=$(lock_field .run_id)
    die 3 "state lock belongs to run ${rid:-unknown}; refusing to save"
  fi
}

download_tree_parts() {
  local tree=$1 json=$2 dl=$3
  local -n out=$4
  out=()
  local n i name sha bytes declared file got got_sha expected_bytes=0
  n=$(jq -r --arg t "$tree" '(.trees[$t].parts // []) | length' <<<"$json" 2>/dev/null) || { warn "invalid $tree pointer"; return 1; }
  case $n in
    ''|*[!0-9]*) warn "invalid $tree part count"; return 1 ;;
  esac
  if [ "$n" -lt 1 ]; then
    warn "snapshot has no $tree parts"
    return 1
  fi
  for ((i = 0; i < n; i++)); do
    name=$(jq -r --arg t "$tree" --argjson i "$i" '.trees[$t].parts[$i].name // empty' <<<"$json" 2>/dev/null) || { warn "invalid $tree part name"; return 1; }
    sha=$(jq -r --arg t "$tree" --argjson i "$i" '.trees[$t].parts[$i].sha256 // empty' <<<"$json" 2>/dev/null) || { warn "invalid $tree part sha256"; return 1; }
    bytes=$(jq -r --arg t "$tree" --argjson i "$i" '.trees[$t].parts[$i].bytes // empty' <<<"$json" 2>/dev/null) || { warn "invalid $tree part size"; return 1; }
    case $name in
      "$tree"-*.tar.zst.part-*) ;;
      *) warn "unsafe $tree part name"; return 1 ;;
    esac
    if [[ ! $name =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "unsafe $tree part name characters"
      return 1
    fi
    if [[ ! $sha =~ ^[0-9a-f]{64}$ ]]; then
      warn "invalid sha256 for $name"
      return 1
    fi
    case $bytes in
      ''|*[!0-9]*) warn "invalid size for $name"; return 1 ;;
    esac
    file=$dl/$name
    if ! gh_state release download "$STATE_TAG" --repo "$STATE_REPO" --pattern "$name" --dir "$dl" --clobber >/dev/null 2>&1; then
      warn "download failed for $name"
      return 1
    fi
    [ -f "$file" ] || { warn "downloaded file missing for $name"; return 1; }
    got=$(stat -c %s -- "$file" 2>/dev/null) || { warn "cannot stat $name"; return 1; }
    [ "$got" = "$bytes" ] || { warn "size mismatch for $name"; return 1; }
    got_sha=$(sha256sum -- "$file" | awk '{print $1}') || { warn "cannot hash $name"; return 1; }
    [ "$got_sha" = "$sha" ] || { warn "sha256 mismatch for $name"; return 1; }
    expected_bytes=$((expected_bytes + bytes))
    out+=("$file")
  done
  declared=$(jq -r --arg t "$tree" '.trees[$t].bytes // empty' <<<"$json" 2>/dev/null) || declared=
  case $declared in
    ''|*[!0-9]*) ;;
    *) if [ "$declared" != "$expected_bytes" ]; then warn "$tree bytes mismatch with pointer"; return 1; fi ;;
  esac
  return 0
}

validate_archive_listing() {
  local archive=$1 tree=$2 listing=$DL_DIR/listing-$2.txt
  tar --zstd -tf "$archive" > "$listing" 2>/dev/null || { warn "cannot list $tree archive"; return 1; }
  [ -s "$listing" ] || { warn "empty $tree archive"; return 1; }
  if grep -Eq '(^/|(^|/)\.\.(/|$))' "$listing"; then
    warn "unsafe member path in $tree archive"
    return 1
  fi
  return 0
}

validate_tree_symlinks() {
  local root
  root=$(readlink -m -- "$1" 2>/dev/null) || return 1
  shift
  local -a allowed=()
  local link target resolved bad=0 a ra ok
  allowed+=("$root")
  for a in "$@"; do
    ra=$(readlink -m -- "$a" 2>/dev/null) || ra=$a
    allowed+=("$ra")
  done
  while IFS= read -r -d '' link; do
    target=$(readlink -- "$link" 2>/dev/null) || continue
    case $target in
      /*) resolved=$(readlink -m -- "$target" 2>/dev/null) || resolved= ;;
      *) resolved=$(readlink -m -- "$(dirname -- "$link")/$target" 2>/dev/null) || resolved= ;;
    esac
    if [ -z "$resolved" ]; then
      warn "cannot resolve symlink in state: $link"
      bad=1
      continue
    fi
    ok=false
    for a in "${allowed[@]}"; do
      case $resolved in
        "$a"|"$a"/*) ok=true ;;
      esac
    done
    if [ "$ok" != true ]; then
      warn "unsafe symlink escaping state roots: $link"
      bad=1
    fi
  done < <(find "$root" -type l -print0 2>/dev/null)
  [ "$bad" -eq 0 ]
}

clear_dir() {
  local d=$1
  mkdir -p -- "$d" || return 1
  find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || return 1
  chmod 700 -- "$d" || return 1
}

restore_pointer() {
  local ptr=$1 json id
  json=$(jq -c -e . "$ptr" 2>/dev/null) || { warn "invalid snapshot pointer: ${ptr##*/}"; return 1; }
  id=$(jq -r '.id // empty' <<<"$json" 2>/dev/null) || { warn "invalid snapshot id"; return 1; }
  if [[ ! $id =~ ^[A-Za-z0-9._-]+$ ]]; then
    warn "unsafe snapshot id in ${ptr##*/}"
    return 1
  fi
  rm -rf -- "$DL_DIR"
  mkdir -p -- "$DL_DIR" || { warn "cannot create download directory"; return 1; }
  local -a home_parts=() work_parts=()
  download_tree_parts home "$json" "$DL_DIR" home_parts || return 1
  download_tree_parts work "$json" "$DL_DIR" work_parts || return 1
  cat -- "${home_parts[@]}" > "$DL_DIR/home.tar.zst" || { warn "cannot assemble home archive"; return 1; }
  cat -- "${work_parts[@]}" > "$DL_DIR/work.tar.zst" || { warn "cannot assemble work archive"; return 1; }
  validate_archive_listing "$DL_DIR/home.tar.zst" home || return 1
  validate_archive_listing "$DL_DIR/work.tar.zst" work || return 1
  clear_dir "$DSH_HOME" || { warn "cannot clear DSH_HOME"; return 1; }
  clear_dir "$DSH_WORKSPACE" || { warn "cannot clear DSH_WORKSPACE"; return 1; }
  tar --zstd -xpf "$DL_DIR/home.tar.zst" -C "$DSH_HOME" || { warn "home extract failed"; return 1; }
  tar --zstd -xpf "$DL_DIR/work.tar.zst" -C "$DSH_WORKSPACE" || { warn "work extract failed"; return 1; }
  chmod 700 -- "$DSH_HOME" "$DSH_WORKSPACE" || return 1
  validate_tree_symlinks "$DSH_HOME" "$DSH_WORKSPACE" || return 1
  validate_tree_symlinks "$DSH_WORKSPACE" "$DSH_HOME" || return 1
  if [ -f "$DSH_HOME/storages/workspace.json" ] \
     && ! jq -e . "$DSH_HOME/storages/workspace.json" >/dev/null 2>&1; then
    warn "restored storages/workspace.json is not valid JSON"
    return 1
  fi
  return 0
}

restore_state() {
  RESTORED_FROM=none
  RESTORED_ID=
  mkdir -p -- "$RUNTIME_DIR" || die 1 "cannot create runtime directory"
  local cur=$STATE_FILE prev=$PREV_FILE
  if [ -f "$cur" ]; then
    if restore_pointer "$cur"; then
      RESTORED_FROM=state
      RESTORED_ID=$(jq -r '.id // empty' "$cur" 2>/dev/null || true)
      log "restored snapshot ${RESTORED_ID} from state.json"
      return 0
    fi
    warn "current snapshot is unreadable; trying previous snapshot"
    if [ -f "$prev" ]; then
      if restore_pointer "$prev"; then
        RESTORED_FROM=prev
        RESTORED_ID=$(jq -r '.id // empty' "$prev" 2>/dev/null || true)
        log "restored previous snapshot ${RESTORED_ID} from state.prev.json"
        rm -f -- "$cur" || true
        return 0
      fi
      die 4 "both current and previous state snapshots are unreadable; refusing to start empty"
    fi
    die 4 "current state snapshot is unreadable and no previous snapshot exists; refusing to start empty"
  elif [ -f "$prev" ]; then
    if restore_pointer "$prev"; then
      RESTORED_FROM=prev
      RESTORED_ID=$(jq -r '.id // empty' "$prev" 2>/dev/null || true)
      log "restored previous snapshot ${RESTORED_ID} from state.prev.json"
      return 0
    fi
    die 4 "previous state snapshot is unreadable; refusing to start empty"
  else
    log "no state snapshot found (first run); starting with empty state"
    mkdir -p -- "$DSH_HOME" "$DSH_WORKSPACE" || die 6 "cannot create state directories"
    return 0
  fi
}

ensure_state_release() {
  if gh_state release view "$STATE_TAG" --repo "$STATE_REPO" >/dev/null 2>&1; then
    return 0
  fi
  local target
  target=$(git_state rev-parse HEAD 2>/dev/null || true)
  if ! gh_state release create "$STATE_TAG" --repo "$STATE_REPO" --target "$target" --title "dsh-state" --notes "Private dsh-web state snapshots" >/dev/null 2>&1; then
    if ! gh_state release view "$STATE_TAG" --repo "$STATE_REPO" >/dev/null 2>&1; then
      warn "cannot create state release $STATE_TAG"
      return 1
    fi
  fi
  return 0
}

upload_part() {
  local file=$1 i
  for i in 1 2 3; do
    if gh_state release upload "$STATE_TAG" "$file" --repo "$STATE_REPO" --clobber >/dev/null 2>&1; then
      return 0
    fi
    warn "upload attempt $i failed for ${file##*/}"
    sleep $((i * 2))
  done
  return 1
}

verify_uploaded_parts() {
  local names p n
  names=$(gh_state release view "$STATE_TAG" --repo "$STATE_REPO" --json assets --jq '.assets[].name' 2>/dev/null) || { warn "cannot list release assets"; return 1; }
  for p in "$@"; do
    n=${p##*/}
    if ! grep -Fxq -- "$n" <<<"$names"; then
      warn "upload verification failed for $n"
      return 1
    fi
  done
  return 0
}

write_session_stub() {
  local log=$1 dir=$2 mtime=$3 tmp=$4
  local stub_name header_tmp stub_tmp
  stub_name=$(basename -- "$log")
  header_tmp="$tmp/stub-header.$$"
  stub_tmp="$tmp/stub.$$"
  if [[ "$log" == *.zstd ]]; then
    ( set +o pipefail; zstd -q -dc -- "$log" 2>/dev/null | head -n 1 > "$header_tmp" ) || true
    if [ ! -s "$header_tmp" ]; then rm -f -- "$header_tmp" "$stub_tmp"; return 1; fi
    if ! zstd -q -c -- "$header_tmp" > "$stub_tmp"; then rm -f -- "$header_tmp" "$stub_tmp"; return 1; fi
  else
    if ! head -n 1 -- "$log" > "$stub_tmp"; then rm -f -- "$header_tmp" "$stub_tmp"; return 1; fi
  fi
  if [ ! -s "$stub_tmp" ]; then rm -f -- "$header_tmp" "$stub_tmp"; return 1; fi
  chmod 600 -- "$stub_tmp" 2>/dev/null || true
  touch -d "@$mtime" -- "$stub_tmp" 2>/dev/null || true
  if ! mv -f -- "$stub_tmp" "$dir/$stub_name"; then rm -f -- "$header_tmp" "$stub_tmp"; return 1; fi
  find "$dir" -maxdepth 1 -type f -name 'session.v*.jsonl*' ! -name "$stub_name" -delete 2>/dev/null || true
  : > "$dir/session.lock" || true
  chmod 600 -- "$dir/session.lock" 2>/dev/null || true
  rm -f -- "$header_tmp"
  return 0
}

archive_cold_sessions() {
  ARCHIVED_COUNT=0
  ARCHIVED_BYTES=0
  [ "$SESSION_ARCHIVE_ENABLED" = true ] || return 0
  local sessions_root="$STAGE_DIR/home/sessions"
  local index_dir="$STAGE_DIR/home/.session-archive"
  local index_file="$index_dir/index.json"
  local prev_index="$RUNTIME_DIR/sessions-index.json"
  [ -f "$prev_index" ] || prev_index="$DSH_HOME/.session-archive/index.json"
  [ -d "$sessions_root" ] || return 0
  mkdir -p -- "$index_dir" || { warn "cannot create session archive index directory"; return 1; }
  chmod 700 -- "$index_dir" 2>/dev/null || true

  local prev_json='{"version":1,"sessions":{}}'
  if [ -f "$prev_index" ] && jq -e . "$prev_index" >/dev/null 2>&1; then
    prev_json=$(jq -c . "$prev_index") || prev_json='{"version":1,"sessions":{}}'
  fi

  local -a rows=()
  local dir project id log mtime bytes
  while IFS= read -r -d '' dir; do
    project=${dir#"$sessions_root"/}
    project=${project%%/*}
    id=${dir##*/}
    [[ "$project" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    log="$dir/session.v4.jsonl.zstd"
    if [ ! -f "$log" ]; then
      log=$(find "$dir" -maxdepth 1 -type f -name 'session.v*.jsonl*' -print 2>/dev/null | sort | tail -n 1 || true)
    fi
    [ -n "$log" ] && [ -f "$log" ] || continue
    mtime=$(stat -c %Y -- "$log" 2>/dev/null || printf '0')
    bytes=$(stat -c %s -- "$log" 2>/dev/null || printf '0')
    case $mtime in ''|*[!0-9]*) mtime=0 ;; esac
    case $bytes in ''|*[!0-9]*) bytes=0 ;; esac
    rows+=("$mtime"$'\t'"$project"$'\t'"$id"$'\t'"$dir"$'\t'"$log"$'\t'"$bytes")
  done < <(find "$sessions_root" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)

  local idx_json='{"version":1,"sessions":{}}'
  if (( ${#rows[@]} == 0 )); then
    write_json_file "$index_file" "$idx_json" || return 1
    chmod 600 -- "$index_file" 2>/dev/null || true
    return 0
  fi

  local -a sorted=()
  mapfile -t sorted < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1nr)
  local now hot_cutoff i=0 new_count=0 reused_count=0
  local row prev_entry prev_full updated archived tmp asset sha
  now=$(now_epoch)
  hot_cutoff=$(( now - SESSION_HOT_DAYS * 86400 ))
  tmp=$(mktemp -d "$RUN_DIR/session-archive.XXXXXX") || { warn "cannot create session archive temp directory"; return 1; }

  for row in "${sorted[@]}"; do
    IFS=$'\t' read -r mtime project id dir log bytes <<<"$row"

    prev_entry=$(jq -c --arg id "$id" '.sessions[$id] // empty' <<<"$prev_json" 2>/dev/null || true)
    prev_full=0
    if [ -n "$prev_entry" ]; then
      prev_full=$(jq -r '.full_bytes // 0' <<<"$prev_entry" 2>/dev/null || printf '0')
      case $prev_full in ''|*[!0-9]*) prev_full=0 ;; esac
    fi

    if [ -n "$prev_entry" ] && (( prev_full > 0 && bytes < prev_full )); then
      idx_json=$(jq -c --arg id "$id" --argjson e "$prev_entry" '.sessions[$id]=$e' <<<"$idx_json") \
        || { warn "cannot carry archived session $id in the index"; rm -rf -- "$tmp"; return 1; }
      ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
      ARCHIVED_BYTES=$((ARCHIVED_BYTES + prev_full))
      continue
    fi

    if (( i < SESSION_HOT_MAX )) || (( mtime >= hot_cutoff )); then
      i=$((i + 1))
      continue
    fi
    i=$((i + 1))
    if (( mtime > now - SESSION_ARCHIVE_MIN_AGE_SEC )); then
      continue
    fi

    if [ -n "$prev_entry" ] && (( prev_full > 0 && bytes == prev_full )); then
      if ! write_session_stub "$log" "$dir" "$mtime" "$tmp"; then
        warn "cannot replace unchanged session $id with a stub; keeping its full log"
        continue
      fi
      idx_json=$(jq -c --arg id "$id" --argjson e "$prev_entry" '.sessions[$id]=$e' <<<"$idx_json") \
        || { warn "cannot carry archived session $id in the index"; rm -rf -- "$tmp"; return 1; }
      ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
      ARCHIVED_BYTES=$((ARCHIVED_BYTES + prev_full))
      reused_count=$((reused_count + 1))
      continue
    fi

    if ! tar -C "$sessions_root" --zstd -cpf "$tmp/$id.tar.zst" "$project/$id" 2>/dev/null; then
      warn "cannot archive session $id; keeping its full log"
      continue
    fi
    sha=$(sha256sum -- "$tmp/$id.tar.zst" | awk '{print $1}') \
      || { warn "cannot hash archived session $id"; rm -f -- "$tmp/$id.tar.zst"; continue; }
    asset="session-${id}-${sha:0:16}.tar.zst"
    mv -f -- "$tmp/$id.tar.zst" "$tmp/$asset" \
      || { warn "cannot name archived session $id"; continue; }
    if [ "$(stat -c %s -- "$tmp/$asset" 2>/dev/null || printf '0')" -gt 1900000000 ]; then
      warn "archived session $id exceeds the release asset limit; keeping its full log"
      rm -f -- "$tmp/$asset"
      continue
    fi
    if ! upload_part "$tmp/$asset"; then
      warn "cannot upload archived session $id; keeping its full log"
      rm -f -- "$tmp/$asset"
      continue
    fi
    if ! verify_uploaded_parts "$tmp/$asset"; then
      warn "uploaded archive for session $id is missing from the release; keeping its full log"
      rm -f -- "$tmp/$asset"
      continue
    fi
    if ! write_session_stub "$log" "$dir" "$mtime" "$tmp"; then
      warn "cannot replace session $id with a stub; keeping its full log"
      rm -f -- "$tmp/$asset"
      continue
    fi

    updated=$(date -u -d "@$mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || now_iso)
    archived=$(now_iso)
    idx_json=$(jq -c \
      --arg id "$id" \
      --arg project "$project" \
      --arg path "sessions/$project/$id" \
      --arg release "$STATE_TAG" \
      --arg asset "$asset" \
      --arg sha "$sha" \
      --argjson full "$bytes" \
      --arg updated "$updated" \
      --arg archived "$archived" \
      '.sessions[$id]={project:$project,path:$path,release:$release,asset:$asset,sha256:$sha,full_bytes:$full,updated_at:$updated,archived_at:$archived}' \
      <<<"$idx_json") || { warn "cannot index archived session $id"; rm -rf -- "$tmp"; return 1; }
    ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
    ARCHIVED_BYTES=$((ARCHIVED_BYTES + bytes))
    new_count=$((new_count + 1))
    rm -f -- "$tmp/$asset"
  done

  write_json_file "$index_file" "$idx_json" || { warn "cannot write session archive index"; rm -rf -- "$tmp"; return 1; }
  chmod 600 -- "$index_file" 2>/dev/null || true
  rm -rf -- "$tmp"
  log "session archive: ${ARCHIVED_COUNT} archived (${ARCHIVED_BYTES}B), ${new_count} newly archived, ${reused_count} reused"
  return 0
}

write_gitleaks_config() {
  cat > "$GITLEAKS_CONFIG" <<'GITLEAKS_EOF'
title = "dsh-state"
[extend]
useDefault = true

[[allowlists]]
description = "DSH credential store persisted by DSH_PERSIST_CREDENTIALS"
paths = ['''\.credentials\.yaml$''']
GITLEAKS_EOF
  chmod 600 -- "$GITLEAKS_CONFIG" 2>/dev/null || true
}

run_gitleaks() {
  if [ "$DSH_SKIP_GITLEAKS" = true ]; then
    warn "gitleaks scan skipped by DSH_SKIP_GITLEAKS"
    return 0
  fi
  need_cmd gitleaks
  write_gitleaks_config
  if gitleaks detect --source "$STAGE_DIR" --no-git --redact --config "$GITLEAKS_CONFIG" \
      --report-format json --report-path "$RUN_DIR/gitleaks-report.json" \
      >"$RUN_DIR/gitleaks.log" 2>&1; then
    return 0
  fi
  warn "gitleaks reported findings or failed; see $RUN_DIR/gitleaks.log (redacted)"
  return "$GITLEAKS_EXIT_CODE"
}

cleanup_old_assets() {
  local cur prev names name id
  cur=$(jq -r '.id // empty' "$STATE_FILE" 2>/dev/null) || return 1
  [ -n "$cur" ] || return 1
  prev=
  if [ -f "$PREV_FILE" ]; then
    prev=$(jq -r '.id // empty' "$PREV_FILE" 2>/dev/null) || prev=
  fi
  names=$(gh_state release view "$STATE_TAG" --repo "$STATE_REPO" --json assets --jq '.assets[].name' 2>/dev/null) || return 1
  local -a all_names=()
  while IFS= read -r name; do
    if [ -n "$name" ]; then all_names+=("$name"); fi
  done <<<"$names"
  local -A keep=()
  keep["$cur"]=1
  if [ -n "$prev" ]; then keep["$prev"]=1; fi
  local -A ids=()
  for name in "${all_names[@]}"; do
    case $name in
      home-*.tar.zst.part-*|work-*.tar.zst.part-*)
        id=${name#*-}
        id=${id%.tar.zst.part-*}
        if [ -n "$id" ]; then ids["$id"]=1; fi
        ;;
    esac
  done
  local extras=0
  if [ "$STATE_KEEP_SNAPSHOTS" -gt 2 ]; then
    extras=$((STATE_KEEP_SNAPSHOTS - 2))
  fi
  if [ "$extras" -gt 0 ]; then
    local -a candidates=()
    while IFS= read -r id; do
      if [ -n "$id" ]; then candidates+=("$id"); fi
    done < <(
      for id in "${!ids[@]}"; do
        if [ -n "${keep[$id]:-}" ]; then continue; fi
        printf '%s %s\n' "${id#*-}" "$id"
      done | sort -r | awk -v n="$extras" 'NR<=n {print $2}'
    )
    for id in "${candidates[@]}"; do
      keep["$id"]=1
    done
  fi
  for name in "${all_names[@]}"; do
    case $name in
      home-*.tar.zst.part-*|work-*.tar.zst.part-*) ;;
      *) continue ;;
    esac
    id=${name#*-}
    id=${id%.tar.zst.part-*}
    if [ -z "${keep[$id]:-}" ]; then
      gh_state release delete-asset "$STATE_TAG" "$name" --repo "$STATE_REPO" --yes >/dev/null 2>&1 || warn "could not delete old asset $name"
    fi
  done
  return 0
}

cmd_init() {
  if [ $# -ne 0 ]; then usage >&2; exit 64; fi
  require_repo_env
  need_cmd gh
  need_cmd git
  need_cmd jq
  need_cmd tar
  need_cmd zstd
  need_cmd sha256sum
  need_cmd find
  need_cmd readlink
  need_cmd df
  validate_workspace_paths
  mkdir -p -- "$RUN_DIR" || die 6 "cannot create RUN_DIR"
  chmod 700 -- "$RUN_DIR" 2>/dev/null || true
  CLEAN_DOWNLOADS=true
  ensure_clone
  check_private_repo
  checkout_control
  check_lock_or_takeover
  local free
  free=$(free_mb_of "$RUN_DIR")
  if [ "$free" -lt "$STATE_MIN_FREE_MB" ]; then
    die 6 "only ${free}MB free on scratch (< ${STATE_MIN_FREE_MB}MB)"
  fi
  local need_mb=0 root_free
  if [ -f "$STATE_FILE" ] && pointer_valid "$STATE_FILE"; then
    need_mb=$(jq -r '.raw_mb // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  elif [ -f "$PREV_FILE" ] && pointer_valid "$PREV_FILE"; then
    need_mb=$(jq -r '.raw_mb // 0' "$PREV_FILE" 2>/dev/null || echo 0)
  fi
  case $need_mb in
    ''|*[!0-9]*) need_mb=0 ;;
  esac
  root_free=$(free_mb_of /)
  if [ "$need_mb" -gt 0 ] && [ "$root_free" -lt $((need_mb + 1024)) ]; then
    die 6 "only ${root_free}MB free on /, need ~$((need_mb + 1024))MB to restore ${need_mb}MB of state"
  fi
  restore_state
  chmod 700 -- "$DSH_HOME" "$DSH_WORKSPACE" || die 6 "cannot chmod state directories"
  if [ "$DSH_PERSIST_CREDENTIALS" = true ] && [ -f "$DSH_HOME/.credentials.yaml" ]; then
    chmod 600 -- "$DSH_HOME/.credentials.yaml" || die 6 "cannot chmod persisted credentials"
  fi
  if [ "$RESTORED_FROM" != none ] && [ "$DSH_PERSIST_CREDENTIALS" != true ] && [ -f "$DSH_HOME/.credentials.yaml" ]; then
    rm -f -- "$DSH_HOME/.credentials.yaml" || die 6 "cannot remove persisted credentials"
    log "removed .credentials.yaml from restored home (default credentials are not persisted)"
  fi
  rm -f -- "$URL_FILE" || true
  write_lock
  update_meta_init
  commit_control "state: init run $GITHUB_RUN_ID"
  log "init complete: restored=${RESTORED_FROM} host=$HOST_NAME"
}

cmd_publish_url() {
  local url=
  if [ $# -gt 1 ]; then usage >&2; exit 64; fi
  if [ $# -eq 1 ]; then
    url=$1
  else
    if [ ! -f "$RUN_DIR/url.txt" ]; then
      die 64 "publish-url: $RUN_DIR/url.txt not found and no URL argument given"
    fi
    url=$(cat -- "$RUN_DIR/url.txt") || die 1 "cannot read $RUN_DIR/url.txt"
  fi
  [ -n "$url" ] || die 64 "publish-url: empty URL"
  case $url in
    *' '*|*$'\t'*|*$'\r'*|*$'\n'*) die 64 "publish-url: URL must not contain whitespace" ;;
  esac
  case $url in
    http://*|https://*) ;;
    *) die 64 "publish-url: URL must start with http:// or https://" ;;
  esac
  require_repo_env
  need_cmd gh
  need_cmd git
  need_cmd jq
  need_cmd sha256sum
  require_control_clone
  require_lock_ours
  check_private_repo
  local sha
  sha=$(printf '%s' "$url" | sha256sum | awk '{print $1}') || die 1 "cannot hash URL"
  mkdir -p -- "$RUNTIME_DIR" || die 1 "cannot create runtime directory"
  if ! (umask 077; printf '%s' "$url" > "$URL_FILE.tmp"); then
    rm -f -- "$URL_FILE.tmp" 2>/dev/null || true
    die 1 "cannot write runtime/url.txt"
  fi
  chmod 600 -- "$URL_FILE.tmp" || die 1 "cannot chmod runtime/url.txt"
  mv -f -- "$URL_FILE.tmp" "$URL_FILE" || die 1 "cannot install runtime/url.txt"
  update_meta_publish "$sha"
  refresh_lock_heartbeat
  commit_control "state: publish url"
  log "published runtime/url.txt (0600)"
}

cmd_save() {
  local final=false
  while [ $# -gt 0 ]; do
    case $1 in
      --final) final=true ;;
      *) usage >&2; exit 64 ;;
    esac
    shift
  done
  require_repo_env
  need_cmd gh
  need_cmd git
  need_cmd jq
  need_cmd rsync
  need_cmd tar
  need_cmd zstd
  need_cmd split
  need_cmd sha256sum
  need_cmd stat
  need_cmd du
  need_cmd df
  need_cmd find
  [ -f "$EXCLUDES" ] || die 6 "exclude file missing: $EXCLUDES"
  validate_workspace_paths
  require_control_clone
  require_lock_ours
  check_private_repo
  CLEAN_STAGING=true
  mkdir -p -- "$RUN_DIR" || die 6 "cannot create RUN_DIR"
  chmod 700 -- "$RUN_DIR" 2>/dev/null || true
  local free
  free=$(free_mb_of "$RUN_DIR")
  if [ "$free" -lt "$STATE_MIN_FREE_MB" ]; then
    die 6 "only ${free}MB free on scratch (< ${STATE_MIN_FREE_MB}MB)"
  fi
  local start_epoch
  start_epoch=$(now_epoch)
  rm -rf -- "$STAGE_DIR"
  mkdir -p -- "$STAGE_DIR/home" "$STAGE_DIR/work" || die 1 "cannot create staging directories"
  local -a cred_args=()
  if [ "$DSH_PERSIST_CREDENTIALS" = true ]; then
    cred_args+=(--include=.credentials.yaml)
  fi
  local rs_rc=0
  rsync -a "${cred_args[@]}" --exclude-from="$EXCLUDES" "$DSH_HOME/" "$STAGE_DIR/home/" || rs_rc=$?
  if [ "$rs_rc" -eq 24 ]; then
    warn "rsync reported vanished files for home; continuing"
  elif [ "$rs_rc" -ne 0 ]; then
    die 1 "rsync failed for home (exit $rs_rc)"
  fi
  rs_rc=0
  rsync -a --exclude-from="$EXCLUDES" "$DSH_WORKSPACE/" "$STAGE_DIR/work/" || rs_rc=$?
  if [ "$rs_rc" -eq 24 ]; then
    warn "rsync reported vanished files for work; continuing"
  elif [ "$rs_rc" -ne 0 ]; then
    die 1 "rsync failed for work (exit $rs_rc)"
  fi
  validate_tree_symlinks "$STAGE_DIR/home" "$STAGE_DIR/work" "$DSH_HOME" "$DSH_WORKSPACE" || die 6 "unsafe symlink in staged home state"
  validate_tree_symlinks "$STAGE_DIR/work" "$STAGE_DIR/home" "$DSH_HOME" "$DSH_WORKSPACE" || die 6 "unsafe symlink in staged work state"
  run_gitleaks || exit $?
  ensure_state_release || die 1 "cannot ensure state release"
  ARCHIVED_COUNT=0
  ARCHIVED_BYTES=0
  archive_cold_sessions || die 4 "session archive failed"
  local raw_mb
  raw_mb=$(du -sm -- "$STAGE_DIR" | awk '{print $1}') || die 1 "cannot measure staged state"
  case $raw_mb in
    ''|*[!0-9]*) die 1 "invalid staged state size" ;;
  esac
  if [ "$raw_mb" -gt "$STATE_BUDGET_MB" ]; then
    die 2 "staged state ${raw_mb}MB exceeds hard budget ${STATE_BUDGET_MB}MB"
  fi
  local over_warn=false
  if [ "$raw_mb" -ge "$STATE_WARN_MB" ]; then
    over_warn=true
    warn "staged state ${raw_mb}MB reached soft budget ${STATE_WARN_MB}MB; continuing"
  fi
  local snapshot_id current_id
  snapshot_id="${GITHUB_RUN_ID}-$(ts_compact)"
  current_id=
  if [ -f "$STATE_FILE" ]; then
    current_id=$(jq -r '.id // empty' "$STATE_FILE" 2>/dev/null || true)
  fi
  if [ "$current_id" = "$snapshot_id" ]; then
    warn "snapshot id collision with current pointer; waiting for a new timestamp"
    sleep 1
    snapshot_id="${GITHUB_RUN_ID}-$(ts_compact)"
    if [ "$current_id" = "$snapshot_id" ]; then
      snapshot_id="${snapshot_id}-${RANDOM}"
    fi
  fi
  local -a all_parts=()
  local parts_home_json='[]' parts_work_json='[]' total_bytes=0 total_parts=0 home_bytes=0 work_bytes=0
  local tree prefix rc
  for tree in home work; do
    prefix=$STAGE_DIR/${tree}-${snapshot_id}.tar.zst.part-
    rc=0
    tar -C "$STAGE_DIR/$tree" -cpf - --zstd . | split -b "${STATE_ASSET_PART_MB}MiB" -d -a 2 - "$prefix" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$rc" -eq 1 ]; then
        warn "tar reported changed files while archiving $tree; continuing"
      else
        die 1 "tar/split failed for $tree (exit $rc)"
      fi
    fi
    local -a files=("$prefix"*)
    if [ ! -e "${files[0]}" ]; then die 1 "no archive parts produced for $tree"; fi
    local tree_json='[]' tree_bytes=0 p name bytes sha
    for p in "${files[@]}"; do
      name=${p##*/}
      bytes=$(stat -c %s -- "$p") || die 1 "cannot stat archive part $name"
      sha=$(sha256sum -- "$p" | awk '{print $1}') || die 1 "cannot hash archive part $name"
      tree_bytes=$((tree_bytes + bytes))
      tree_json=$(jq -c --arg n "$name" --arg s "$sha" --argjson b "$bytes" '. + [{name:$n,sha256:$s,bytes:$b}]' <<<"$tree_json") || die 1 "cannot build part manifest"
      all_parts+=("$p")
    done
    total_bytes=$((total_bytes + tree_bytes))
    total_parts=$((total_parts + ${#files[@]}))
    case $tree in
      home)
        parts_home_json=$tree_json
        home_bytes=$tree_bytes
        ;;
      work)
        parts_work_json=$tree_json
        work_bytes=$tree_bytes
        ;;
    esac
  done
  local created_at snapshot_json
  created_at=$(now_iso)
  snapshot_json=$(jq -c -n \
    --arg id "$snapshot_id" \
    --arg run_id "$GITHUB_RUN_ID" \
    --arg created_at "$created_at" \
    --arg host "$HOST_NAME" \
    --arg version "$DSH_VERSION" \
    --argjson final "$final" \
    --argjson raw_mb "$raw_mb" \
    --argjson total_bytes "$total_bytes" \
    --argjson total_parts "$total_parts" \
    --argjson over_warn "$over_warn" \
    --argjson home "$parts_home_json" \
    --argjson work "$parts_work_json" \
    --argjson home_bytes "$home_bytes" \
    --argjson work_bytes "$work_bytes" \
    --argjson archived_count "$ARCHIVED_COUNT" \
    --argjson archived_bytes "$ARCHIVED_BYTES" \
    '{id:$id,run_id:$run_id,created_at:$created_at,host:$host,
      version:(if $version=="" then null else $version end),final:$final,
      raw_mb:$raw_mb,archive_bytes:$total_bytes,parts:$total_parts,over_warn:$over_warn,
      archived:{sessions:$archived_count,bytes:$archived_bytes},
      trees:{home:{bytes:$home_bytes,parts:$home},work:{bytes:$work_bytes,parts:$work}}}') || die 1 "cannot build snapshot manifest"
  ensure_state_release || die 1 "cannot ensure state release"
  local p
  for p in "${all_parts[@]}"; do
    upload_part "$p" || die 1 "failed to upload ${p##*/}"
  done
  verify_uploaded_parts "${all_parts[@]}" || die 1 "release asset verification failed"
  if [ -f "$STATE_FILE" ] && pointer_valid "$STATE_FILE"; then
    cp -f -- "$STATE_FILE" "$PREV_FILE.tmp" || die 1 "cannot stage previous pointer"
    mv -f -- "$PREV_FILE.tmp" "$PREV_FILE" || die 1 "cannot install previous pointer"
  elif [ -f "$STATE_FILE" ]; then
    warn "current state pointer is invalid; keeping the existing previous pointer"
  fi
  write_json_file "$STATE_FILE" "$snapshot_json"
  local base count duration
  base=$(meta_base)
  count=$(jq -r '.checkpoint.count // 0' <<<"$base" 2>/dev/null || true)
  case $count in
    ''|*[!0-9]*) count=0 ;;
  esac
  count=$((count + 1))
  duration=$(( $(now_epoch) - start_epoch ))
  update_meta_save "$snapshot_id" "$raw_mb" "$total_bytes" "$total_parts" "$final" "$over_warn" "$duration" "$count" "$ARCHIVED_COUNT" "$ARCHIVED_BYTES"
  refresh_lock_heartbeat
  if [ -f "$STAGE_DIR/home/.session-archive/index.json" ]; then
    cp -f -- "$STAGE_DIR/home/.session-archive/index.json" "$RUNTIME_DIR/sessions-index.json.tmp" \
      && chmod 600 -- "$RUNTIME_DIR/sessions-index.json.tmp" 2>/dev/null \
      && mv -f -- "$RUNTIME_DIR/sessions-index.json.tmp" "$RUNTIME_DIR/sessions-index.json" \
      || warn "cannot publish session archive index to the control branch"
  else
    rm -f -- "$RUNTIME_DIR/sessions-index.json" 2>/dev/null || true
  fi
  commit_control "state: save snapshot $snapshot_id (raw ${raw_mb}MB)"
  if ! cleanup_old_assets; then
    warn "old state asset cleanup failed; continuing"
  fi
  log "saved snapshot $snapshot_id: raw=${raw_mb}MB archive=${total_bytes}B parts=$total_parts final=$final"
}

cmd_should_stop() {
  if [ $# -ne 0 ]; then usage >&2; exit 64; fi
  require_env STATE_REPO
  require_env STATE_REPO_TOKEN
  require_env GITHUB_RUN_ID
  validate_state_repo
  need_cmd gh
  local value rc=0
  value=$(gh_state variable get DSH_STOP --repo "$STATE_REPO" --json value --jq '.value' 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case $value in
      *"Not Found"*|*"not found"*|*"HTTP 404"*) exit 1 ;;
      *)
        value=${value//$'\n'/ }
        warn "cannot read DSH_STOP from $STATE_REPO (gh exit $rc): $value"
        exit 1
        ;;
    esac
  fi
  value=${value//$'\r'/}
  value=${value//$'\n'/}
  case $value in
    all|"$GITHUB_RUN_ID")
      log "stop requested by DSH_STOP"
      exit 0
      ;;
  esac
  exit 1
}

cmd_release_lock() {
  if [ $# -ne 0 ]; then usage >&2; exit 64; fi
  if [ ! -d "$STATE_CLONE/.git" ]; then
    log "no state clone; nothing to release"
    return 0
  fi
  require_repo_env
  need_cmd gh
  need_cmd git
  need_cmd jq
  require_control_clone
  if [ ! -f "$LOCK_FILE" ]; then
    log "no state lock to release"
    return 0
  fi
  if ! jq -e . "$LOCK_FILE" >/dev/null 2>&1; then
    warn "state lock is invalid; removing it"
    rm -f -- "$LOCK_FILE" || die 1 "cannot remove invalid lock"
    update_meta_release
    commit_control "state: release invalid lock for run $GITHUB_RUN_ID"
    log "invalid state lock released"
    return 0
  fi
  if ! lock_is_ours; then
    local rid
    rid=$(lock_field .run_id)
    die 3 "refusing to remove lock owned by run ${rid:-unknown}"
  fi
  rm -f -- "$LOCK_FILE" || die 1 "cannot remove lock"
  update_meta_release
  commit_control "state: release lock for run $GITHUB_RUN_ID"
  log "state lock released"
}

cmd_status() {
  need_cmd jq
  local snap=null prev=null last=null raw=null
  local lock_present=false lock_ours=false lock_stale=false
  local url_published=false staging_present=false
  local free=0 fd=/ age
  if [ -f "$STATE_FILE" ] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    snap=$(jq -c '{id,created_at,raw_mb,archive_bytes,parts,host,version,final,over_warn}' "$STATE_FILE" 2>/dev/null || printf 'null')
    raw=$(jq -r '.raw_mb // empty' "$STATE_FILE" 2>/dev/null || true)
  fi
  if [ -f "$PREV_FILE" ] && jq -e . "$PREV_FILE" >/dev/null 2>&1; then
    prev=$(jq -c '{id,created_at,raw_mb,archive_bytes,parts,final}' "$PREV_FILE" 2>/dev/null || printf 'null')
  fi
  if [ -f "$META_FILE" ] && jq -e . "$META_FILE" >/dev/null 2>&1; then
    last=$(jq -c '.checkpoint // null' "$META_FILE" 2>/dev/null || printf 'null')
    if [ -z "$raw" ]; then
      raw=$(jq -r '.checkpoint.last_raw_mb // empty' "$META_FILE" 2>/dev/null || true)
    fi
  fi
  case $raw in
    ''|*[!0-9]*) raw=null ;;
  esac
  if [ -f "$LOCK_FILE" ]; then
    lock_present=true
    if lock_is_ours; then lock_ours=true; fi
    age=$(lock_age_minutes)
    if [ "$age" -ge "$STATE_LOCK_STALE_MIN" ]; then lock_stale=true; fi
  fi
  if [ -f "$URL_FILE" ]; then url_published=true; fi
  if [ -d "$STAGE_DIR" ]; then staging_present=true; fi
  if [ -d "$RUN_DIR" ]; then fd=$RUN_DIR; elif [ -d "$STATE_CLONE" ]; then fd=$STATE_CLONE; fi
  free=$(df -Pm -- "$fd" 2>/dev/null | awk 'NR==2 {print $4}') || free=0
  case $free in
    ''|*[!0-9]*) free=0 ;;
  esac
  local over_warn=false over_budget=false
  if [ "$raw" != null ]; then
    if [ "$raw" -ge "$STATE_WARN_MB" ]; then over_warn=true; fi
    if [ "$raw" -gt "$STATE_BUDGET_MB" ]; then over_budget=true; fi
  fi
  jq -c -n \
    --arg run_id "$GITHUB_RUN_ID" \
    --arg state_repo "$STATE_REPO" \
    --argjson snapshot "$snap" \
    --argjson previous "$prev" \
    --argjson last_save "$last" \
    --argjson raw_mb "$raw" \
    --argjson lock_present "$lock_present" \
    --argjson lock_ours "$lock_ours" \
    --argjson lock_stale "$lock_stale" \
    --argjson url_published "$url_published" \
    --argjson staging_present "$staging_present" \
    --argjson free_mb "$free" \
    --argjson budget_mb "$STATE_BUDGET_MB" \
    --argjson warn_mb "$STATE_WARN_MB" \
    --argjson over_warn "$over_warn" \
    --argjson over_budget "$over_budget" \
    '{
       run_id:(if $run_id=="" then null else $run_id end),
       state_repo:(if $state_repo=="" then null else $state_repo end),
       snapshot:$snapshot,
       previous:$previous,
       raw_mb:$raw_mb,
       last_save:$last_save,
       lock:{present:$lock_present,ours:$lock_ours,stale:$lock_stale},
       url_published:$url_published,
       staging_present:$staging_present,
       free_mb:$free_mb,
       budget_mb:$budget_mb,
       warn_mb:$warn_mb,
       over_warn:$over_warn,
       over_budget:$over_budget
     }'
}

cmd=${1:-}
if [ $# -gt 0 ]; then shift; fi
case $cmd in
  init) cmd_init "$@" ;;
  publish-url) cmd_publish_url "$@" ;;
  save) cmd_save "$@" ;;
  should-stop) cmd_should_stop "$@" ;;
  release-lock) cmd_release_lock "$@" ;;
  status) cmd_status "$@" ;;
  help|-h|--help) usage; exit 0 ;;
  '') usage >&2; exit 64 ;;
  *) usage >&2; exit 64 ;;
esac
