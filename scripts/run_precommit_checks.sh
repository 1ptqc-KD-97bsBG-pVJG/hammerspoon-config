#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

say() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

say "Checking repo hygiene"
scripts/check_repo_hygiene.sh

say "Checking shell script syntax"
while IFS= read -r script; do
  bash -n "$script"
done < <(find scripts githooks -type f \( -name '*.sh' -o -name 'pre-commit' \) | sort)

if command -v lua >/dev/null 2>&1; then
  say "Running Lua regression tests"
  while IFS= read -r test_file; do
    lua "$test_file"
  done < <(find tests -type f -name '*.lua' | sort)
fi

say "Checking git diff formatting"
git diff --check -- . ':(exclude).git'

say "All pre-commit checks passed"
