#!/bin/sh
# Storage-first git compaction for the plug.vim fork in this directory.
# Leaves one plugin checkout holding a single commit (plus the previous tip
# while HEAD@{1} still needs it) and no other remote branches, tags, or
# reflogs. Local branches, stashes and unpublished commits are never dropped.
#
#   plug-compact.sh fetch [<branch>]  PlugUpdate step: fetch only the new tip
#                                     of <branch> (default: the remote's HEAD
#                                     branch, recorded as origin/HEAD) at
#                                     depth 1, then reclaim space. Runs before
#                                     checkout/reset, so the old tip stays
#                                     reachable for HEAD@{1}.
#   plug-compact.sh move <branch>     PlugUpdate step after fetch: check out
#                                     <branch> and `reset --keep` it to
#                                     origin/<branch>, unless already there.
#   plug-compact.sh keep <branch>     PlugCompact: shrink in place at the
#                                     current HEAD without moving it.
#   plug-compact.sh sub               Run inside a submodule (via `git
#                                     submodule foreach`): shrink to its
#                                     checked-out commit.
#
# Extra arguments after <branch> are passed to `git fetch` (e.g. --progress).
# PLUG_NO_CREDENTIAL_HELPER=1 disables credential helpers for network calls.
# `gc --prune=now` assumes nothing else writes to the repository meanwhile.

mode=$1
branch=$2
[ $# -ge 2 ] && shift 2 || shift $#

remote_git() {
  if [ -n "$PLUG_NO_CREDENTIAL_HELPER" ]; then
    git -c credential.helper= "$@"
  else
    git "$@"
  fi
}

shallow_file() {
  echo "$(git rev-parse --git-dir)/shallow"
}

# True when history is already cut at HEAD, so no fetch is needed.
compact_at_head() {
  [ "$(cat "$(shallow_file)" 2>/dev/null)" = "$head" ]
}

# True when commit $1 holds no work of its own: it is a depth-1 boundary, or
# some remote-tracking ref already contains it.
is_published() {
  grep -qx "$1" "$(shallow_file)" 2>/dev/null ||
    [ -n "$(git for-each-ref --contains "$1" --format=x refs/remotes)" ]
}

# Commits that only a reflog still reaches, such as work committed on a
# detached HEAD. Expiring reflogs would let gc delete them. Run before any
# fetch moves the shallow boundary.
reflog_only_commits() {
  { echo HEAD; git for-each-ref --format='%(refname)'; } | grep -vx refs/stash |
    while read -r ref; do
      git reflog exists "$ref" && git reflog show --format=%H "$ref"
    done | sort -u |
    while read -r sha; do
      git cat-file -e "$sha^{commit}" 2>/dev/null || continue
      is_published "$sha" && continue
      [ -n "$(git for-each-ref --contains "$sha" --format=x refs/heads)" ] && continue
      echo "$sha"
    done
}

head=$(git rev-parse HEAD) || exit 1

# Tags that came from upstream (same name and target as a tag on origin) or
# whose commit is published; only these are dropped below. A tag the user made
# on their own commit protects it, so it stays. Offline, only the second test
# applies. Decided before the fetch, which cuts the history that proves a
# commit is published.
published_tags() {
  tags=$(git for-each-ref --format='%(objectname) %(refname)' refs/tags)
  [ -n "$tags" ] || return 0
  upstream=$(remote_git ls-remote --tags --refs origin 2>/dev/null | tr '\t' ' ')
  echo "$tags" |
    while read -r obj ref; do
      if echo "$upstream" | grep -qxF "$obj $ref"; then
        echo "$ref"
      elif sha=$(git rev-parse -q --verify "$ref^{commit}") && is_published "$sha"; then
        echo "$ref"
      fi
    done
}

case $mode in
move)
  origin="refs/remotes/origin/$branch"
  git checkout -q "$branch" -- || exit 1
  # A second, no-op entry would hide the update from HEAD@{1} after checkout
  # already moved to a new branch.
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "$origin")" ] ||
    git reset -q --keep "$origin"
  exit
  ;;
fetch)
  if [ -z "$branch" ]; then
    branch=$(remote_git ls-remote --symref origin HEAD |
      awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2 }')
    [ -n "$branch" ] || branch=$(git symbolic-ref -q --short HEAD) || exit 1
    follow_head=1
  fi
  # The move step overwrites the local branch, so it must hold no work either
  for rev in HEAD "refs/heads/$branch"; do
    sha=$(git rev-parse -q --verify "$rev^{commit}") || continue
    if ! is_published "$sha"; then
      echo "$rev has local commits not on origin; not updating. Push or drop them first." >&2
      exit 1
    fi
  done
  unsafe=$(reflog_only_commits)
  drop_tags=$(published_tags)
  # Also cut history at the current HEAD unless it is already a depth-1
  # boundary (a deep clone from upstream vim-plug). Otherwise the old tip keeps
  # its full history, and once it is only HEAD@{1} nothing would prove it was
  # published, so the next update would skip gc.
  cut_head=
  grep -qx "$head" "$(shallow_file)" 2>/dev/null || cut_head=$head
  git remote set-branches origin "$branch" &&
  remote_git fetch --depth 1 --no-tags "$@" origin \
    "+refs/heads/$branch:refs/remotes/origin/$branch" $cut_head || exit 1
  keep="refs/remotes/origin/$branch"
  # plug.vim reads this file to pick the branch for checkout and reset
  [ -z "$follow_head" ] || git symbolic-ref refs/remotes/origin/HEAD "$keep" || exit 1
  ;;
keep)
  unsafe=$(reflog_only_commits)
  drop_tags=$(published_tags)
  git remote set-branches origin "$branch" || exit 1
  compact_at_head || remote_git fetch -q --depth 1 --no-tags "$@" origin "$head" || exit 1
  git update-ref "refs/remotes/origin/$branch" "$head" || exit 1
  keep="refs/remotes/origin/$branch"
  ;;
sub)
  unsafe=$(reflog_only_commits)
  drop_tags=$(published_tags)
  # Leftover local branches in a submodule only pin history (ycmd's `master`
  # held 3000+ commits). Drop published ones, before the fetch below cuts the
  # history that proves it; keep the checked-out one and any holding work.
  current=$(git symbolic-ref -q HEAD)
  git for-each-ref --format='%(refname)' refs/heads |
    while read -r ref; do
      [ "$ref" != "$current" ] && is_published "$(git rev-parse "$ref")" &&
        git update-ref -d "$ref"
    done
  compact_at_head || remote_git fetch -q --depth 1 --no-tags origin "$head" || exit 1
  keep=
  ;;
*)
  echo "usage: $0 fetch [<branch>] [fetch-args] | move <branch> | keep <branch> [fetch-args] | sub" >&2
  exit 2
  ;;
esac

# Drop every remote-tracking ref and published tag that would pin old
# history, and an origin/HEAD left pointing at a dropped ref. --no-deref:
# deleting the origin/HEAD symref must not delete its target.
origin_head=$(git symbolic-ref -q refs/remotes/origin/HEAD)
git for-each-ref --format='%(refname)' refs/remotes |
  while read -r ref; do
    case $ref in
      "$keep") ;;
      refs/remotes/origin/HEAD) [ -n "$keep" ] && [ "$origin_head" = "$keep" ] ||
        git update-ref --no-deref -d "$ref" ;;
      *) git update-ref --no-deref -d "$ref" ;;
    esac
  done
[ -z "$drop_tags" ] || echo "$drop_tags" |
  while read -r ref; do git update-ref --no-deref -d "$ref"; done

if [ -n "$unsafe" ]; then
  echo "plug-compact: $(echo "$unsafe" | wc -l | tr -d ' ') commit(s) reachable only from a reflog; kept reflogs, skipped gc" >&2
  exit 0
fi

# Expire reflogs so old tips become unreachable, except the stash: its reflog
# is the stash list itself.
{ echo HEAD; git for-each-ref --format='%(refname)'; } | grep -vx refs/stash |
  while read -r ref; do
    git reflog exists "$ref" && git reflog expire --expire=now "$ref"
  done
git gc -q --prune=now
