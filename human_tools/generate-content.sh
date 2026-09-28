#!/bin/bash
# Runs openrouterclient's generate.sh and prints only the content JSON on stdout.
set -euo pipefail

main() {
  local prompt_file="" schema_file="" schema_name="" tag="" api_key=""
  local paid_args=()
  for arg in "$@"; do
    case "$arg" in
      --prompt=*) prompt_file="${arg#*=}" ;;
      --schema=*) schema_file="${arg#*=}" ;;
      --schema-name=*) schema_name="${arg#*=}" ;;
      --tag=*) tag="${arg#*=}" ;;
      --key=*) api_key="${arg#*=}" ;;
      --paid) paid_args=(--paid) ;;
      *) echo "generate-content: unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  if [ -z "$prompt_file" ] || [ -z "$schema_file" ] || [ -z "$schema_name" ] || [ -z "$tag" ] || [ -z "$api_key" ]; then
    echo "usage: generate-content.sh --prompt=<file> --schema=<file> --schema-name=<name> --tag=<tag> --key=<openrouter key> [--paid]" >&2
    exit 2
  fi

  local script_dir library_dir generate_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  library_dir="$script_dir/openrouterclient"
  generate_script="$library_dir/bin/generate.sh"
  if [ ! -e "$library_dir/.git" ]; then
    echo "generate-content: $library_dir is not initialized. Initialize the submodule with:" >&2
    echo "  git -C \"$script_dir\" submodule update --init openrouterclient" >&2
    exit 1
  fi
  # Always runs the library's latest main; .gitmodules sets ignore = all so
  # this moving checkout never shows up as an uncommitted change here.
  git -C "$library_dir" fetch --quiet origin main
  git -C "$library_dir" checkout --quiet --detach origin/main

  local requirements_file result_file
  requirements_file="$(mktemp --suffix=.json)"
  result_file="$(mktemp --suffix=.json)"
  # Expanded now: the EXIT trap runs after main returns, when these locals are gone.
  trap "rm -f '$requirements_file' '$result_file'" EXIT

  # Empty validation rules make the library skip its review/correction loop,
  # so targetQuality is required but never compared against.
  jq -n \
    --rawfile prompt "$prompt_file" \
    --rawfile schema "$schema_file" \
    --arg name "$schema_name" \
    '{
      prompt: $prompt,
      outputSchema: { name: $name, schema: ($schema | fromjson) },
      outputValidationRules: "",
      targetQuality: "high"
    }' > "$requirements_file"

  "$generate_script" --key="$api_key" --tag="$tag" "${paid_args[@]}" "$requirements_file" > "$result_file"
  jq -e '.Content' "$result_file"
}

main "$@"
