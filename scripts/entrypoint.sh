#!/bin/bash
set -euo pipefail

source /scripts/general_utils.sh
source /scripts/minio_utils.sh

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

  log_info "✅ Docs converter initialization completed successfully."
}

# Main execution
if ! main "$@"; then
  log_error "Docs converterbootstrap failed"
  exit 1
fi