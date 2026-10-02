#!/usr/bin/env bash
# Gibt den Workspace für einen Pull Request aus.
# Argument 1: Head-Branch. Argument 2: Zielbranch.
# preview/<name> am Head gewinnt, sonst gilt der Zielbranch.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Aufruf: workspace.sh <head-ref> <base-ref>" >&2
  exit 2
fi

head_ref=$1
base_ref=$2

validate_env() {
  local name=$1
  if [[ "$name" == "default" ]]; then
    echo "Environment 'default' ist nicht erlaubt." >&2
    exit 1
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
    echo "Environment '$name' ist ungültig." >&2
    exit 1
  fi
  if [[ "$name" == "prod" || "$name" == "dev" || "$name" == "staging" ]]; then
    return 0
  fi
  if [[ "$name" == preview-* && "$name" != "preview-" ]]; then
    return 0
  fi
  echo "Environment '$name' ist nicht erlaubt. Erlaubt: prod, dev, staging, preview-<name>." >&2
  exit 1
}

workspace_from_ref() {
  local b=$1
  case "$b" in
    main) echo prod ;;
    develop) echo dev ;;
    staging) echo staging ;;
    preview/*)
      local rest="${b#preview/}"
      if [[ -z "$rest" || "$rest" == *"/"* ]]; then
        echo "Branch '$b' ist kein gültiges Preview-Environment." >&2
        echo "Erlaubt ist genau eine Ebene: preview/<name>." >&2
        exit 1
      fi
      echo "preview-${rest}"
      ;;
    *)
      echo "Branch '$b' ist keinem Environment zugeordnet." >&2
      echo "Erlaubt: main, develop, staging, preview/<name>." >&2
      exit 1
      ;;
  esac
}

if [[ "$head_ref" == preview/* ]]; then
  ws=$(workspace_from_ref "$head_ref")
else
  ws=$(workspace_from_ref "$base_ref")
fi

validate_env "$ws"
printf '%s\n' "$ws"
