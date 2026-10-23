#!/bin/bash
# Run a command in a core worktree at core.lock, with this cloud repository's
# web/ directories overlaid (plan-cloud-split-r1 §4).  Used by CI and by developers.
#   scripts/with-core.sh -- node web/sync/test-sync.mjs
#
# What's overlaid is one cloud commit, resolved once at the start (HEAD), and
# core.lock is read from that same commit: the working tree is never used, so
# uncommitted and untracked files (core.lock included) aren't tested by accident.
# SAGEBRUSH_OVERLAY=worktree overlays the working tree, with its core.lock,
# instead, as an explicit developer mode (CI never sets it).
#
# Every invocation gets its own fresh, clean core worktree, in a directory of
# its own under $TMPDIR, and removes it on exit: nothing an invocation builds or
# installs is seen by another, so concurrent runs can't mix sources or outputs.
# Only immutable git objects are cached, in $SAGEBRUSH_CORE_CACHE/repo.git
# (default ~/.cache/sagebrush-core).  The objects kept are bounded: the 3 most
# recent core.lock commits (refs/lock/<sha>) plus at most
# $SAGEBRUSH_CORE_MAX_ACTIVE (default 4) active worktrees, each a depth-1
# commit.  Each commit is fetched exactly (no tags, depth 1; no fallback to a
# broader fetch).  Past the active cap an invocation waits, up to
# $SAGEBRUSH_CORE_WAIT seconds (default 900), then fails, before fetching.  The
# worktree of an invocation that died without cleaning up is found by its
# recorded pid and start time, and removed before anything else is admitted.
# A failed gc fails the invocation and leaves gc-debt, and no later invocation
# fetches until a gc has succeeded.  Fetches, pruning, gc and worktree
# bookkeeping run under one lock.  Package installs use pnpm's and npm's own
# caches, which are content-addressed.
set -eo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
mode=${SAGEBRUSH_OVERLAY:-commit}
if [ "$mode" = worktree ]; then
  lock=$(cat "$here/core.lock")
else
  cloud=$(git -C "$here" rev-parse --verify -q 'HEAD^{commit}') || { echo "the cloud checkout has no commit to overlay (SAGEBRUSH_OVERLAY=worktree for a working tree)"; exit 1; }
  lock=$(git -C "$here" show "$cloud:core.lock") || { echo "core.lock isn't committed in $cloud"; exit 1; }
fi
sha=$(printf %s "$lock" | tr -d '[:space:]')
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "bad core.lock"; exit 1; }
cache=${SAGEBRUSH_CORE_CACHE:-$HOME/.cache/sagebrush-core}
repo=$cache/repo.git
keep=3
max_active=${SAGEBRUSH_CORE_MAX_ACTIVE:-4}
wait_s=${SAGEBRUSH_CORE_WAIT:-900}
mkdir -p "$cache/active"
exec 9>"$cache/lock"
# (a process's start time, to tell a live owner from a reused pid)
started() { [ -r "/proc/$1/stat" ] && sed 's/^.*) //' "/proc/$1/stat" | cut -d' ' -f20; }
gc() {
  if git -C "$repo" gc -q --prune=now; then rm -f "$cache/gc-debt"; else touch "$cache/gc-debt"; echo "core cache: gc failed; refusing to grow the cache until a gc succeeds"; return 1; fi
}
# (remove an invocation's worktree and directory, under the lock; succeeds only once both are proven
# gone: no directory, and no worktree registered at it.  Until then its active/ entry stays, and counts)
reclaim() {
  git -C "$repo" worktree remove --force "$1/core" 2>/dev/null || true
  rm -rf "$1" 2>/dev/null || true
  git -C "$repo" worktree prune
  [ ! -e "$1" ] || return 1
  local want g; want=$(realpath -m "$1/core/.git")
  for g in "$repo"/worktrees/*/gitdir; do
    [ -e "$g" ] && [ "$(realpath -m "$(cat "$g")")" = "$want" ] && return 1
  done
  return 0
}

waited=0
while :; do
  flock 9
  [ -d "$repo" ] || git init -q --bare "$repo"
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || git -C "$repo" remote add origin "${SAGEBRUSH_CORE_URL:-https://github.com/sagemathinc/sagebrush.git}"
  # (recover dead invocations' worktrees first: their objects stop being roots)
  # (an entry whose removal fails again stays, counted toward the cap: a stuck tree never stops counting)
  recovered=; stuck=0
  for f in "$cache"/active/*; do
    [ -e "$f" ] || continue
    read -r pid start dir < "$f" || true
    if [ -z "$pid" ] || [ "$(started "$pid")" != "$start" ]; then
      if [ -n "$dir" ] && reclaim "$dir"; then rm -f "$f"; recovered=1; else stuck=$((stuck + 1)); echo "core cache: can't remove ${dir:-?} (active/$(basename "$f")); it stays counted until it can be"; fi
    fi
  done
  git -C "$repo" worktree prune
  # (a gc that failed before must succeed before the cache may grow)
  if [ -e "$cache/gc-debt" ] || [ -n "$recovered" ]; then gc || { flock -u 9; exit 1; }; fi
  active=$(ls "$cache/active" | wc -l)
  [ "$active" -lt "$max_active" ] && break
  # (every slot held by a tree that can't be removed: waiting can't help, so fail now)
  [ "$stuck" -lt "$active" ] || { flock -u 9; echo "core cache: all $active active slots are trees that can't be removed; fix them (see above) and rerun"; exit 1; }
  flock -u 9
  [ "$waited" -lt "$wait_s" ] || { echo "core cache: $active active worktrees (the cap is $max_active) for ${wait_s}s; giving up"; exit 1; }
  sleep 2; waited=$((waited + 2))
done
if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
  git -C "$repo" fetch -q --no-tags --depth=1 origin "$sha" || { flock -u 9; echo "can't fetch core $sha"; exit 1; }
  git -C "$repo" cat-file -e "$sha^{commit}" || { flock -u 9; echo "core $sha not found after fetch"; exit 1; }
fi
# (the cache's bound: a ref per kept commit, the oldest pruned beyond $keep, then the unreferenced objects)
git -C "$repo" update-ref "refs/lock/$sha" "$sha"
touch "$cache/used-$sha"
pruned=
for old in $(ls -t "$cache" | sed -n 's/^used-//p' | tail -n +$((keep + 1))); do
  git -C "$repo" update-ref -d "refs/lock/$old" 2>/dev/null || true
  rm -f "$cache/used-$old"
  pruned=1
done
work=$(mktemp -d "${TMPDIR:-/tmp}/sagebrush-core.XXXXXXXX")
core=$work/core
id=$(basename "$work")
echo "$$ $(started $$) $work" > "$cache/active/$id"
cleanup() {
  rc=$?
  flock 9
  if reclaim "$work"; then
    rm -f "$cache/active/$id"
  else
    # (fail closed: the entry stays, so the tree still counts toward the cap, and a later run retries it)
    echo "core cache: couldn't remove $work; it stays counted (active/$id) until a later run removes it"
    [ "$rc" != 0 ] || rc=1
  fi
  flock -u 9
  exit $rc
}
trap cleanup EXIT
git -C "$repo" worktree add -q --detach "$core" "$sha"
[ -z "$pruned" ] || gc || { flock -u 9; exit 1; }
flock -u 9

[ "$(git -C "$core" rev-parse HEAD)" = "$sha" ] || { echo "core worktree isn't at core.lock"; exit 1; }
[ -z "$(git -C "$core" status --porcelain)" ] || { echo "core worktree isn't clean"; exit 1; }
# (each cloud directory replaces core's copy, never merges with it: until core's PR 2, core still has its own old copies)
for d in site files share sync lti; do rm -rf "$core/web/$d"; done
if [ "$mode" = worktree ]; then
  for d in site files share sync lti; do [ -d "$here/web/$d" ] && cp -a "$here/web/$d" "$core/web/$d"; done
else
  dirs=$(for d in site files share sync lti; do git -C "$here" ls-tree -d --name-only "$cloud" "web/$d"; done)
  [ -z "$dirs" ] || git -C "$here" archive "$cloud" $dirs | tar -x -C "$core"
fi
[ "$1" = "--" ] && shift
cd "$core" && "$@"
