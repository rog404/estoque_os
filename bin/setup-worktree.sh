#!/bin/sh
#
# Prepares a fresh git worktree for development by seeding it with the base
# checkout's `deps` and `_build`, instead of compiling both from nothing.
#
# Measured on this project: 47.4s from cold, 3.3s with the caches seeded.
#
# Two techniques from the article this is based on are deliberately NOT here:
#
#   - `cp --reflink=always` (copy-on-write). This machine's repository lives on
#     ext4, which has no reflink support — the call fails and falls back to a
#     real copy anyway. Each worktree therefore costs ~295 MB of actual disk.
#     Worth revisiting on btrfs or XFS.
#
#   - `elixirc_options: [check_cwd: false]`. Measured at no benefit here: all 87
#     project files recompile either way, and the difference was ~60ms, inside
#     the noise. The flag only pays off when a project keeps absolute paths out
#     of compile-time code; ours does not, so it would be risk without a gain.
#
# Usage: bin/setup-worktree.sh /path/to/base/checkout
#
set -eu

base_worktree=${1:?usage: setup-worktree.sh /path/to/base/checkout}

seed_directory() {
  source_path=$1
  destination_path=$2

  [ -d "$source_path" ] || return 0
  mkdir -p "$destination_path"
  cp -a "$source_path/." "$destination_path/"
}

seed_directory "$base_worktree/deps" deps
seed_directory "$base_worktree/_build" _build

# Never skip these. A seeded cache is a guess about the commit, the lockfile,
# the OTP version and MIX_ENV it was built under; these two commands are what
# turn the guess into something checked.
mix deps.get
mix compile
