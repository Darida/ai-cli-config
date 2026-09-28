#!/bin/bash
# Sends one prompt through the openrouterclient submodule's generate.sh and
# prints only the schema-shaped content JSON on stdout; its logs go to stderr.
set -euo pipefail

main() {
  local prompt_file="" schema_file="" schema_name="" tag="" api_key=""
  for arg in "$@"; do
    case "$arg" in
      --prompt=*) prompt_file="${arg#*=}" ;;
      --schema=*) schema_file="${arg#*=}" ;;
      --schema-name=*) schema_name="${arg#*=}" ;;
      --tag=*) tag="${arg#*=}" ;;
      --key=*) api_key="${arg#*=}" ;;
      *) echo "generate-content: unknown argument: $arg" >&2; exit 2 ;;
    esac
  done
  if [ -z "$prompt_file" ] || [ -z "$schema_file" ] || [ -z "$schema_name" ] || [ -z "$tag" ] || [ -z "$api_key" ]; then
    echo "usage: generate-content.sh --prompt=<file> --schema=<file> --schema-name=<name> --tag=<tag> --key=<openrouter key>" >&2
    exit 2
  fi

  local script_dir generate_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  generate_script="$script_dir/openrouterclient/bin/generate.sh"
  if [ ! -x "$generate_script" ]; then
    echo "generate-content: $generate_script not found. Initialize the submodule with:" >&2
    echo "  git -C \"$script_dir\" submodule update --init openrouterclient" >&2
    exit 1
  fi

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

  "$generate_script" --key="$api_key" --tag="$tag" "$requirements_file" > "$result_file"
  jq -e '.Content' "$result_file"
}

main "$@"
