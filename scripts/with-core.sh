#!/bin/bash
# Run a command in a core worktree at core.lock, with this cloud repository's
# web/ directories overlaid (plan-cloud-split-r1 §4).  Used by CI and by developers.
#   scripts/with-core.sh -- node web/sync/test-sync.mjs
#
# What's overlaid is the cloud repository's committed HEAD (git archive), never
# its working tree: uncommitted and untracked files aren't tested by accident.
# SAGEBRUSH_OVERLAY=worktree overlays the working tree instead, as an explicit
# developer mode (CI never sets it).
#
# Every invocation gets its own fresh, clean core worktree, in a directory of
# its own under $TMPDIR, and removes it on exit: nothing an invocation builds or
# installs is seen by another, so concurrent runs can't mix sources or outputs.
# Only immutable git objects are cached, in $SAGEBRUSH_CORE_CACHE/repo.git
# (default ~/.cache/sagebrush-core), and only for the 3 most recent core.lock
# commits: each is fetched exactly (no tags, depth 1; no fallback to a broader
# fetch), and older ones are pruned.  Fetches, pruning and worktree bookkeeping
# run under one lock.  Package installs use pnpm's and npm's own caches, which
# are content-addressed.
set -eo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sha=$(tr -d '[:space:]' < "$here/core.lock")
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "bad core.lock"; exit 1; }
cache=${SAGEBRUSH_CORE_CACHE:-$HOME/.cache/sagebrush-core}
repo=$cache/repo.git
keep=3
mkdir -p "$cache"
exec 9>"$cache/lock"

flock 9
[ -d "$repo" ] || git init -q --bare "$repo"
git -C "$repo" remote get-url origin >/dev/null 2>&1 || git -C "$repo" remote add origin "${SAGEBRUSH_CORE_URL:-https://github.com/sagemathinc/sagebrush.git}"
if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
  git -C "$repo" fetch -q --no-tags --depth=1 origin "$sha" || { echo "can't fetch core $sha"; exit 1; }
  git -C "$repo" cat-file -e "$sha^{commit}" || { echo "core $sha not found after fetch"; exit 1; }
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
git -C "$repo" worktree prune
work=$(mktemp -d "${TMPDIR:-/tmp}/sagebrush-core.XXXXXXXX")
core=$work/core
git -C "$repo" worktree add -q --detach "$core" "$sha"
[ -z "$pruned" ] || git -C "$repo" gc -q --prune=now 2>/dev/null || true
flock -u 9
cleanup() {
  flock 9
  git -C "$repo" worktree remove --force "$core" 2>/dev/null || true
  git -C "$repo" worktree prune
  flock -u 9
  rm -rf "$work"
}
trap cleanup EXIT

[ "$(git -C "$core" rev-parse HEAD)" = "$sha" ] || { echo "core worktree isn't at core.lock"; exit 1; }
[ -z "$(git -C "$core" status --porcelain)" ] || { echo "core worktree isn't clean"; exit 1; }
# (each cloud directory replaces core's copy, never merges with it: until core's PR 2, core still has its own old copies)
for d in site files share sync lti; do rm -rf "$core/web/$d"; done
if [ "${SAGEBRUSH_OVERLAY:-commit}" = worktree ]; then
  for d in site files share sync lti; do [ -d "$here/web/$d" ] && cp -a "$here/web/$d" "$core/web/$d"; done
else
  git -C "$here" rev-parse --verify -q HEAD >/dev/null || { echo "the cloud checkout has no commit to overlay (SAGEBRUSH_OVERLAY=worktree for a working tree)"; exit 1; }
  dirs=$(cd "$here" && for d in site files share sync lti; do git ls-tree -d --name-only HEAD "web/$d" 2>/dev/null; done)
  [ -z "$dirs" ] || git -C "$here" archive HEAD $dirs | tar -x -C "$core"
fi
[ "$1" = "--" ] && shift
cd "$core" && "$@"
