#!/bin/bash
# with-core.sh's isolation (LIMIT-CLOUD2-1, -2; CORR-SPLIT2-2): two different
# cloud commits overlaid at once on the same core.lock each see only their own
# sources, and leave nothing behind; only the committed tree is overlaid, never
# untracked or uncommitted files (unless SAGEBRUSH_OVERLAY=worktree); a stale
# directory in the cache isn't trusted; the cache keeps only git objects.
#   scripts/test-with-core.sh
set -eo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-with-core.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
export SAGEBRUSH_CORE_CACHE=$tmp/cache TMPDIR=$tmp
fail=0
for x in a b; do
  mkdir -p "$tmp/$x/scripts" "$tmp/$x/web/sync"
  cp "$here/scripts/with-core.sh" "$tmp/$x/scripts/" && cp "$here/core.lock" "$tmp/$x/"
  echo "sentinel $x" > "$tmp/$x/web/sync/SENTINEL"
  git -C "$tmp/$x" init -q && git -C "$tmp/$x" add -A && git -C "$tmp/$x" -c user.name=t -c user.email=t@t commit -q -m "$x"
done
# (astra's fixture: an untracked file and an uncommitted edit in a's working tree, and an old-layout
# directory at $cache/<sha> holding a wrong tree, none of which may be used)
echo "untracked" > "$tmp/a/web/sync/UNTRACKED"
echo "dirty" > "$tmp/a/web/sync/SENTINEL.dirty"; echo "edited" >> "$tmp/a/web/sync/SENTINEL"
mkdir -p "$tmp/cache/$(cat "$here/core.lock")/web" && echo wrong > "$tmp/cache/$(cat "$here/core.lock")/web/WRONG"
# (each holds its tree for a while, writes into it, and reads back only its own)
"$tmp/a/scripts/with-core.sh" -- bash -c 'sleep 3; echo built-a > web/sync/OUT; sleep 2; cat web/sync/SENTINEL web/sync/OUT; pwd' > "$tmp/a.out" &
pa=$!
"$tmp/b/scripts/with-core.sh" -- bash -c 'sleep 1; echo built-b > web/sync/OUT; sleep 3; cat web/sync/SENTINEL web/sync/OUT; pwd' > "$tmp/b.out" &
pb=$!
wait $pa || fail=1; wait $pb || fail=1
grep -qx 'sentinel a' "$tmp/a.out" && grep -qx 'built-a' "$tmp/a.out" && ! grep -q 'sentinel b\|built-b' "$tmp/a.out" || { echo "FAIL: overlay a saw another's files"; cat "$tmp/a.out"; fail=1; }
grep -qx 'sentinel b' "$tmp/b.out" && grep -qx 'built-b' "$tmp/b.out" && ! grep -q 'sentinel a\|built-a' "$tmp/b.out" || { echo "FAIL: overlay b saw another's files"; cat "$tmp/b.out"; fail=1; }
[ "$(sed -n 3p "$tmp/a.out")" != "$(sed -n 3p "$tmp/b.out")" ] || { echo "FAIL: both ran in one tree"; fail=1; }
for x in a b; do d=$(sed -n 3p "$tmp/$x.out"); [ ! -e "$d" ] || { echo "FAIL: $d left behind"; fail=1; }; done
[ -z "$(git -C "$tmp/cache/repo.git" worktree list | tail -n +2)" ] || { echo "FAIL: worktrees left registered"; fail=1; }
# (a failing command's status comes back, and its tree is removed too)
set +e; "$tmp/a/scripts/with-core.sh" -- bash -c 'pwd > '"$tmp"'/c.dir; exit 7'; rc=$?; set -e
[ "$rc" = 7 ] || { echo "FAIL: exit status $rc, not 7"; fail=1; }
[ ! -e "$(cat "$tmp/c.dir")" ] || { echo "FAIL: a failed run's tree was left"; fail=1; }
ls "$tmp/cache" | grep -qv -E '^(repo\.git|lock|used-[0-9a-f]{40})$' && { echo "FAIL: the cache holds more than objects"; ls "$tmp/cache"; fail=1; }
# (the default overlays the committed tree only; the old-layout cache directory is never used)
"$tmp/a/scripts/with-core.sh" -- bash -c 'test ! -e web/sync/UNTRACKED && test ! -e web/sync/SENTINEL.dirty && ! grep -q edited web/sync/SENTINEL && test ! -e web/WRONG && [ "$(git rev-parse HEAD)" = "$(cat '"$tmp"'/a/core.lock)" ]' || { echo "FAIL: the commit overlay used working-tree files or a stale cache"; fail=1; }
# (the explicit developer mode overlays the working tree)
SAGEBRUSH_OVERLAY=worktree "$tmp/a/scripts/with-core.sh" -- bash -c 'test -e web/sync/UNTRACKED && grep -q edited web/sync/SENTINEL' || { echo "FAIL: worktree mode didn't overlay the working tree"; fail=1; }
[ $fail = 0 ] && echo "with-core isolation: all passed" || exit 1
