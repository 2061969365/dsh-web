#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ROOT=$(mktemp -d)
trap 'rm -rf -- "$ROOT"' EXIT

export DSH_HOME="$ROOT/home"
export RUN_DIR="$ROOT/run"
export STAGE_DIR="$ROOT/stage"
export RUNTIME_DIR="$ROOT/runtime"
export STATE_TAG=test-state
export UPLOAD_DIR="$ROOT/uploads"
export SESSION_ARCHIVE_ENABLED=true
export SESSION_HOT_MAX=1
export SESSION_HOT_DAYS=1
export SESSION_ARCHIVE_MIN_AGE_SEC=1

mkdir -p "$DSH_HOME/sessions/proj" "$RUN_DIR" "$RUNTIME_DIR" "$STAGE_DIR/home" "$STAGE_DIR/work" "$UPLOAD_DIR"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }
warn() { printf 'warn: %s\n' "$*" >&2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }
write_json_file() {
  local file=$1 json=$2 tmp=$1.tmp
  printf '%s\n' "$json" > "$tmp"
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file"
}
upload_part() {
  cp -- "$1" "$UPLOAD_DIR/"
}
verify_uploaded_parts() {
  local p
  for p in "$@"; do
    [ -f "$UPLOAD_DIR/${p##*/}" ] || return 1
  done
}

make_session() {
  local id=$1 age=$2 dir
  dir="$DSH_HOME/sessions/proj/$id"
  mkdir -p "$dir"
  {
    printf '{"type":"session","id":"%s"}\n' "$id"
    printf '{"type":"event","i":1}\n'
    printf '{"type":"event","i":2}\n'
    printf '{"type":"event","i":3}\n'
  } > "$ROOT/$id.jsonl"
  zstd -q -c -- "$ROOT/$id.jsonl" > "$dir/session.v4.jsonl.zstd"
  printf '{"title":"%s"}\n' "$id" > "$dir/state.json"
  touch -d "$age days ago" "$dir/session.v4.jsonl.zstd"
}

make_session s1 4
make_session s2 3
make_session s3 2
full1=$(stat -c %s "$DSH_HOME/sessions/proj/s1/session.v4.jsonl.zstd")
full2=$(stat -c %s "$DSH_HOME/sessions/proj/s2/session.v4.jsonl.zstd")
full3=$(stat -c %s "$DSH_HOME/sessions/proj/s3/session.v4.jsonl.zstd")

sed -n '/^write_session_stub() {/,/^}/p' "$REPO_ROOT/dsh-actions/state.sh" > "$ROOT/functions.sh"
sed -n '/^archive_cold_sessions() {/,/^}/p' "$REPO_ROOT/dsh-actions/state.sh" >> "$ROOT/functions.sh"
# shellcheck disable=SC1090
source "$ROOT/functions.sh"

stage_home() {
  rm -rf -- "$STAGE_DIR"
  mkdir -p "$STAGE_DIR/home" "$STAGE_DIR/work"
  cp -a "$DSH_HOME/sessions" "$STAGE_DIR/home/"
}

stage_home
ARCHIVED_COUNT=0
ARCHIVED_BYTES=0
archive_cold_sessions

index="$STAGE_DIR/home/.session-archive/index.json"
[ -f "$index" ] || fail 'index was not written'
[ "$(jq '.sessions | length' "$index")" -eq 2 ] || fail 'expected two archived sessions'
[ "$(jq -r '.sessions.s1.full_bytes' "$index")" = "$full1" ] || fail 's1 full_bytes mismatch'
[ "$(jq -r '.sessions.s2.full_bytes' "$index")" = "$full2" ] || fail 's2 full_bytes mismatch'
if jq -e '.sessions.s3' "$index" >/dev/null 2>&1; then fail 's3 should be hot'; fi
[ -f "$STAGE_DIR/home/sessions/proj/s1/session.v4.jsonl.zstd" ] || fail 's1 stub missing'
[ -f "$STAGE_DIR/home/sessions/proj/s2/session.v4.jsonl.zstd" ] || fail 's2 stub missing'
[ "$(stat -c %s "$STAGE_DIR/home/sessions/proj/s1/session.v4.jsonl.zstd")" -lt "$full1" ] || fail 's1 was not stubbed'
[ "$(stat -c %s "$STAGE_DIR/home/sessions/proj/s3/session.v4.jsonl.zstd")" = "$full3" ] || fail 's3 was stubbed'
[ "$(find "$UPLOAD_DIR" -maxdepth 1 -name 'session-*.tar.zst' | wc -l)" -eq 2 ] || fail 'expected two archive uploads'

for id in s1 s2; do
  asset=$(find "$UPLOAD_DIR" -maxdepth 1 -name "session-$id-*.tar.zst" -print -quit)
  [ -n "$asset" ] || fail "$id archive missing"
  mkdir -p "$ROOT/extract-$id"
  tar --zstd -xf "$asset" -C "$ROOT/extract-$id"
  extracted="$ROOT/extract-$id/proj/$id/session.v4.jsonl.zstd"
  [ -f "$extracted" ] || fail "$id archive does not contain the full log"
  zstd -q -dc -- "$extracted" > "$ROOT/$id.full.jsonl"
  grep -q '"i":3' "$ROOT/$id.full.jsonl" || fail "$id archive is incomplete"
done

cp -- "$index" "$RUNTIME_DIR/sessions-index.json"
uploads_before=$(find "$UPLOAD_DIR" -maxdepth 1 -name 'session-*.tar.zst' | wc -l)
stage_home
ARCHIVED_COUNT=0
ARCHIVED_BYTES=0
archive_cold_sessions
uploads_after=$(find "$UPLOAD_DIR" -maxdepth 1 -name 'session-*.tar.zst' | wc -l)
[ "$uploads_before" -eq "$uploads_after" ] || fail 'unchanged full logs were uploaded again'
[ "$(jq '.sessions | length' "$index")" -eq 2 ] || fail 'second run lost archive entries'
[ "$(stat -c %s "$STAGE_DIR/home/sessions/proj/s1/session.v4.jsonl.zstd")" -lt "$full1" ] || fail 'second run did not stub s1'

cp -a "$STAGE_DIR/home" "$ROOT/stub-home"
stage_home
rm -rf -- "$STAGE_DIR/home"
cp -a "$ROOT/stub-home" "$STAGE_DIR/home"
ARCHIVED_COUNT=0
ARCHIVED_BYTES=0
archive_cold_sessions
[ "$(find "$UPLOAD_DIR" -maxdepth 1 -name 'session-*.tar.zst' | wc -l)" -eq "$uploads_after" ] || fail 'stub carry uploaded again'
[ "$(jq '.sessions | length' "$index")" -eq 2 ] || fail 'stub carry lost archive entries'

printf 'session archive tests passed\n'
