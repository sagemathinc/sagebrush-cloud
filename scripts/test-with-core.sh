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
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT  # (u+w: the r4 cases leave read-only trees on failure)
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
rm -rf "$tmp/cache/$(cat "$here/core.lock")"  # (the planted old-layout directory: this test made it)
ls "$tmp/cache" | grep -qv -E '^(repo\.git|lock|active|used-[0-9a-f]{40})$' && { echo "FAIL: the cache holds more than objects"; ls "$tmp/cache"; fail=1; }
[ -z "$(ls "$tmp/cache/active")" ] || { echo "FAIL: active entries left"; fail=1; }
# (the default overlays the committed tree only; the old-layout cache directory is never used)
"$tmp/a/scripts/with-core.sh" -- bash -c 'test ! -e web/sync/UNTRACKED && test ! -e web/sync/SENTINEL.dirty && ! grep -q edited web/sync/SENTINEL && test ! -e web/WRONG && [ "$(git rev-parse HEAD)" = "$(cat '"$tmp"'/a/core.lock)" ]' || { echo "FAIL: the commit overlay used working-tree files or a stale cache"; fail=1; }
# (the explicit developer mode overlays the working tree)
SAGEBRUSH_OVERLAY=worktree "$tmp/a/scripts/with-core.sh" -- bash -c 'test -e web/sync/UNTRACKED && grep -q edited web/sync/SENTINEL' || { echo "FAIL: worktree mode didn't overlay the working tree"; fail=1; }

# ---- r3: a fixture core of 6 commits, so locks, pruning, gc and the active cap can be driven exactly
fx=$tmp/fx; mkdir -p "$fx/core"; git -C "$fx/core" init -q
for i in 1 2 3 4 5 6; do
  mkdir -p "$fx/core/web"; touch "$fx/core/web/.keep"; echo "core $i" > "$fx/core/CORE"
  git -C "$fx/core" add -A; git -C "$fx/core" -c user.name=t -c user.email=t@t commit -q -m "c$i"
  eval "c$i=$(git -C "$fx/core" rev-parse HEAD)"
done
# (a cloud fixture whose committed core.lock is $1, in its own directory $fx/cloud-$1, so concurrent runs never share one)
mkcloud() {
  cl=$fx/cloud-$1; rm -rf "$cl"; mkdir -p "$cl/scripts" "$cl/web/sync"
  cp "$here/scripts/with-core.sh" "$cl/scripts/"; echo "$1" > "$cl/core.lock"; echo cloud > "$cl/web/sync/CLOUD"
  git -C "$cl" init -q; git -C "$cl" add -A; git -C "$cl" -c user.name=t -c user.email=t@t commit -q -m cloud
}
export SAGEBRUSH_CORE_URL=$fx/core
fxrun() { cl=$fx/cloud-$1; shift; SAGEBRUSH_CORE_CACHE=$fx/cache "$cl/scripts/with-core.sh" "$@"; }
# (astra's dirty lock: committed A, working tree B; the default uses A, worktree mode B)
mkcloud "$c1"; echo "$c2" > "$fx/cloud-$c1/core.lock"
[ "$(fxrun "$c1" -- cat CORE)" = "core 1" ] || { echo "FAIL: the default mode used the working tree's core.lock"; fail=1; }
[ "$(SAGEBRUSH_OVERLAY=worktree fxrun "$c1" -- cat CORE)" = "core 2" ] || { echo "FAIL: worktree mode didn't use the working tree's core.lock"; fail=1; }
# (a cloud commit with no core.lock committed is refused)
git -C "$fx/cloud-$c1" rm -q --cached core.lock; git -C "$fx/cloud-$c1" -c user.name=t -c user.email=t@t commit -q -m nolock
fxrun "$c1" -- true >/dev/null 2>&1 && { echo "FAIL: a commit without core.lock was accepted"; fail=1; }
# (more than 3 distinct locks: only the newest 3 refs stay, and the pack is stable once pruned)
for c in "$c1" "$c2" "$c3" "$c4" "$c5"; do mkcloud "$c"; fxrun "$c" -- true || { echo "FAIL: a run at $c"; fail=1; }; done
refs=$(git -C "$fx/cache/repo.git" for-each-ref --format='%(refname)' refs/lock | sort | tr '\n' ' ')
[ "$refs" = "$(printf 'refs/lock/%s\n' "$c3" "$c4" "$c5" | sort | tr '\n' ' ')" ] || { echo "FAIL: kept refs $refs"; fail=1; }
for c in "$c1" "$c2"; do git -C "$fx/cache/repo.git" cat-file -e "$c^{commit}" 2>/dev/null && { echo "FAIL: pruned $c still in the cache"; fail=1; }; done
n1=$(git -C "$fx/cache/repo.git" count-objects -v | grep -E '^(count|in-pack)' | tr '\n' ' ')
fxrun "$c5" -- true; n2=$(git -C "$fx/cache/repo.git" count-objects -v | grep -E '^(count|in-pack)' | tr '\n' ' ')
[ "$n1" = "$n2" ] || { echo "FAIL: objects changed on a cached rerun ($n1 / $n2)"; fail=1; }
# (an injected gc failure fails the run and leaves gc-debt; the next run fetches nothing until a gc succeeds)
chmod a-w "$fx/cache/repo.git/objects/pack"
mkcloud "$c6"; fxrun "$c6" -- true >/dev/null 2>&1 && { echo "FAIL: a run whose gc failed succeeded"; fail=1; }
[ -e "$fx/cache/gc-debt" ] || { echo "FAIL: no gc-debt after a failed gc"; fail=1; }
mkcloud "$c1"; fxrun "$c1" -- true >/dev/null 2>&1 && { echo "FAIL: a run with gc-debt succeeded"; fail=1; }
git -C "$fx/cache/repo.git" cat-file -e "$c1^{commit}" 2>/dev/null && { echo "FAIL: a run fetched while in gc-debt"; fail=1; }
chmod u+w "$fx/cache/repo.git/objects/pack"
fxrun "$c1" -- true || { echo "FAIL: the run after the gc recovered"; fail=1; }
[ ! -e "$fx/cache/gc-debt" ] || { echo "FAIL: gc-debt stayed after a good gc"; fail=1; }
# (the active cap: with 2, a third concurrent run waits until one ends; with no wait allowed, it fails before fetching)
export SAGEBRUSH_CORE_MAX_ACTIVE=2
mkcloud "$c2"; mkcloud "$c3"; mkcloud "$c4"
fxrun "$c2" -- bash -c 'sleep 4' & p1=$!
fxrun "$c3" -- bash -c 'sleep 4' & p2=$!
sleep 2
SAGEBRUSH_CORE_WAIT=0 fxrun "$c4" -- true >/dev/null 2>&1 && { echo "FAIL: a run past the cap started"; fail=1; }
t0=$(date +%s); fxrun "$c4" -- true || { echo "FAIL: a waiting run"; fail=1; }; t1=$(date +%s)
[ $((t1 - t0)) -ge 1 ] || { echo "FAIL: the run past the cap didn't wait"; fail=1; }
wait $p1 $p2
[ -z "$(git -C "$fx/cache/repo.git" worktree list | tail -n +2)" ] && [ -z "$(ls "$fx/cache/active")" ] || { echo "FAIL: worktrees left after the cap runs"; fail=1; }
# (an invocation killed without its cleanup: the next one removes its worktree before admitting more)
SAGEBRUSH_CORE_CACHE=$fx/cache "$fx/cloud-$c4/scripts/with-core.sh" -- bash -c 'sleep 30; : withcore-kill-fixture' & pk=$!; sleep 2
kill -9 $pk; wait $pk 2>/dev/null || true; pkill -9 -f '[w]ithcore-kill-fixture' 2>/dev/null || true
[ -n "$(ls "$fx/cache/active")" ] || { echo "FAIL: the killed run left no active entry to recover"; fail=1; }
fxrun "$c4" -- true || { echo "FAIL: the run after a kill"; fail=1; }
[ -z "$(git -C "$fx/cache/repo.git" worktree list | tail -n +2)" ] && [ -z "$(ls "$fx/cache/active")" ] || { echo "FAIL: the killed run's worktree wasn't recovered"; fail=1; }
[ -z "$(ls -d "$tmp"/sagebrush-core.* 2>/dev/null)" ] || { echo "FAIL: worktree directories left"; fail=1; }
# (r4: a cleanup that fails keeps its active entry, so the tree still counts, until a later run removes it)
entry_dir() { cut -d' ' -f3 "$1"; }
nentries() { ls "$fx/cache/active" | wc -l; }
ntrees() { ls -d "$tmp"/sagebrush-core.* 2>/dev/null | wc -l; }
# (an rm failure: the worktree goes, but a file the run left in its directory can't be removed)
fxrun "$c4" -- bash -c 'mkdir -p ../stuck/d && touch ../stuck/d/f && chmod a-w ../stuck/d' >/dev/null 2>&1 && { echo "FAIL: a run whose cleanup failed exited 0"; fail=1; }
[ "$(nentries)" = 1 ] && [ "$(ntrees)" = 1 ] || { echo "FAIL: after an rm failure: $(nentries) entries, $(ntrees) trees"; fail=1; }
d=$(entry_dir "$fx/cache/active/"*)
# (still stuck: the next run can't remove it either, keeps the entry, and still runs, with 1 of 2 slots taken)
fxrun "$c4" -- true >/dev/null 2>&1 || { echo "FAIL: a run beside one stuck tree"; fail=1; }
[ "$(nentries)" = 1 ] && [ -e "$d" ] || { echo "FAIL: the stuck tree's entry was dropped"; fail=1; }
chmod -R u+w "$d"
fxrun "$c4" -- true || { echo "FAIL: the run after the rm failure was fixed"; fail=1; }
[ "$(nentries)" = 0 ] && [ "$(ntrees)" = 0 ] || { echo "FAIL: the fixed tree wasn't recovered"; fail=1; }
# (a worktree-remove failure: the run's whole directory can't be written)
fxrun "$c4" -- bash -c 'chmod a-w ..' >/dev/null 2>&1 && { echo "FAIL: a run whose worktree remove failed exited 0"; fail=1; }
[ "$(nentries)" = 1 ] && [ "$(ntrees)" = 1 ] || { echo "FAIL: after a worktree-remove failure: $(nentries) entries, $(ntrees) trees"; fail=1; }
d1=$(entry_dir "$fx/cache/active/"*)
# (repeated: a second stuck tree fills the cap of 2; the next run fails at once, and nothing exceeds the cap)
fxrun "$c3" -- bash -c 'chmod a-w ..' >/dev/null 2>&1 || true
[ "$(nentries)" = 2 ] && [ "$(ntrees)" = 2 ] || { echo "FAIL: two stuck runs: $(nentries) entries, $(ntrees) trees"; fail=1; }
t0=$(date +%s); fxrun "$c2" -- true >/dev/null 2>&1 && { echo "FAIL: a run past a cap of stuck trees started"; fail=1; }; t1=$(date +%s)
[ $((t1 - t0)) -lt 30 ] || { echo "FAIL: a cap of stuck trees didn't fail at once"; fail=1; }
[ "$(nentries)" = 2 ] && [ "$(ntrees)" = 2 ] || { echo "FAIL: the bound moved: $(nentries) entries, $(ntrees) trees"; fail=1; }
for f in "$fx/cache/active/"*; do chmod -R u+w "$(entry_dir "$f")"; done
fxrun "$c2" -- true || { echo "FAIL: the run after the stuck trees were fixed"; fail=1; }
[ "$(nentries)" = 0 ] && [ "$(ntrees)" = 0 ] && [ -z "$(git -C "$fx/cache/repo.git" worktree list | tail -n +2)" ] || { echo "FAIL: stuck trees weren't recovered"; fail=1; }
unset SAGEBRUSH_CORE_MAX_ACTIVE
[ $fail = 0 ] && echo "with-core isolation: all passed" || exit 1
