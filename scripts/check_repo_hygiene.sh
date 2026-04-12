#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failures=0

say() {
  printf '%s\n' "$*"
}

fail() {
  say "FAIL: $*"
  failures=1
}

check_not_tracked() {
  local path="$1"
  local label="$2"
  if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    fail "$label is tracked: $path"
  fi
}

scan_pattern() {
  local label="$1"
  local pattern="$2"
  shift 2
  local files=("$@")

  if [ "${#files[@]}" -eq 0 ]; then
    return
  fi

  local output
  output="$(rg -n --color=never -e "$pattern" -- "${files[@]}" || true)"
  if [ -n "$output" ]; then
    fail "$label"
    say "$output"
  fi
}

scan_repo_pattern() {
  local label="$1"
  local pattern="$2"

  if [ "${#repo_files[@]}" -eq 0 ]; then
    return
  fi

  scan_pattern "$label" "$pattern" "${repo_files[@]}"
}

repo_files=()
while IFS= read -r file; do
  repo_files+=("$file")
done < <(
  git ls-files --cached --others --exclude-standard | grep -v -E '^(scripts/check_repo_hygiene\.sh|docs/repo-hygiene\.md)$' || true
)

check_not_tracked ".DS_Store" ".DS_Store"
check_not_tracked "config.local.lua" "Local config override"

if [ -n "${HOME:-}" ]; then
  scan_repo_pattern "Repo files contain the current machine home path" "${HOME//\//\\/}"
fi

if [ -n "${repo_root:-}" ]; then
  scan_repo_pattern "Repo files contain the current absolute repo path" "${repo_root//\//\\/}"
fi

scan_repo_pattern "Repo files contain a macOS absolute user path" '/Users/[A-Za-z0-9._-]+/'
scan_repo_pattern "Repo files contain a Linux home path" '/home/[A-Za-z0-9._-]+/'
scan_repo_pattern "Repo files contain a Windows user path" 'C:\\Users\\'
scan_repo_pattern "Repo files contain a file:// URI" 'file://'
scan_repo_pattern "Repo files contain a vscode:// URI" 'vscode://'
scan_repo_pattern "Repo files contain a bearer token literal" 'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9._-]+'
scan_repo_pattern "Repo files may contain a GitHub personal access token" 'ghp_[A-Za-z0-9]{20,}'
scan_repo_pattern "Repo files may contain a generic secret token" 'sk-[A-Za-z0-9_-]{20,}'

if [ "$failures" -ne 0 ]; then
  say ""
  say "Repo hygiene checks failed."
  exit 1
fi

say "Repo hygiene checks passed."
