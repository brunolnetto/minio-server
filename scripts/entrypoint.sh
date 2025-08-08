#!/bin/bash
set -euo pipefail

# Resolve directory of THIS file (works both when executed or sourced)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# Ensure helper exists
if [ ! -f "$SCRIPT_DIR/general_utils.sh" ]; then
  echo "🔴 Error: $SCRIPT_DIR/general_utils.sh not found" >&2
  # If this file was sourced, prefer `return` to avoid exiting the caller shell
  return 1 2>/dev/null || exit 1
fi

source "$SCRIPT_DIR/general_utils.sh"
source "$SCRIPT_DIR/minio_utils.sh"

ensure_var_set "MINIO_ROOT_USER"
ensure_var_set "MINIO_ROOT_PASSWORD"
ensure_var_set "MINIO_BUCKET"

setup_minio_wrapper() {
  setup_minio "$MINIO_BUCKET" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
}

setup_postgres_wrapper() {
  setup_postgres "$POSTGRES_HOST" "$POSTGRES_PORT" \
    "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
    "$POSTGRES_DATABASES"
}

main() {
  log_info "Running as user: $(whoami)"

  # Execute each step with individual error handling
  steps=(
    setup_minio_wrapper
  )

  for step in "${steps[@]}"; do
    log_info "▶️ Running step: $step"
    if ! $step; then
      log_error "❌ Step '$step' failed. Check logs above for details."
      exit 1
    fi
  done

  log_info "✅ Minio initialization completed successfully."
}

# Main execution
if ! main "$@"; then
  log_error "Minio bootstrap failed"
  exit 1
fi