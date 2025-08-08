#!/bin/bash
# Robust and modular MinIO bucket & user setup script
# Dependencies: mc (MinIO client), jq, general_utils.sh

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Resolve directory of THIS file (works both when executed or sourced)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# Ensure helper exists
if [ ! -f "$SCRIPT_DIR/general_utils.sh" ]; then
  echo "🔴 Error: $SCRIPT_DIR/general_utils.sh not found" >&2
  # If this file was sourced, prefer `return` to avoid exiting the caller shell
  return 1 2>/dev/null || exit 1
fi

source "$SCRIPT_DIR/general_utils.sh"

: "${MINIO_ENDPOINT:=http://minio:9000}"
: "${MC_ALIAS:=admin}"
: "${MC_ALIAS_TMP:=myminio}"
: "${MINIO_BUCKET:?must be set}"
: "${MINIO_ROOT_USER:?must be set}"
: "${MINIO_ROOT_PASSWORD:?must be set}"

##################################
# 1) Wait for MinIO to be alive  #
##################################
wait_for_minio() {
  local endpoint="$1"
  local user="$2"
  local password="$3"

  log_info "Waiting for MinIO at $endpoint …"
  until mc alias set healthcheck "$endpoint" "$user" "$password" >/dev/null 2>&1 \
        && mc admin info healthcheck >/dev/null 2>&1; do
    log_info "Still waiting for MinIO…"
    sleep 2
  done
  mc alias remove healthcheck >/dev/null 2>&1 || true
  log_info "MinIO is healthy."
}

##################################
# 2) Configure mc alias          #
##################################
ensure_mc_alias() {
  local alias="$1"
  local endpoint="$2"
  local user="$3"
  local password="$4"

  retry 5 2 mc alias set "$alias" "$endpoint" "$user" "$password"
}

##################################
# 3) Bucket operations           #
##################################
ensure_bucket_exists() {
  local alias="$1"
  local bucket="${2}"
  if mc ls "$alias/$bucket" >/dev/null 2>&1; then
    log_warn "Bucket '$bucket' already exists."
  else
    log_info "Creating bucket '$bucket'…"
    retry 5 2 mc mb "$alias/$bucket"
    log_success "Bucket created."
  fi
}

##################################
# 4) Create admin user           #
##################################
: "${ACCESS_LEN:=16}"
: "${SECRET_LEN:=20}"
generate_access_keys() {
  access_key=$(generate_random_string "$ACCESS_LEN")
  secret_key=$(generate_random_string "$SECRET_LEN")
  echo "$access_key" "$secret_key"
}

create_user_credentials() {
  local access_key="$1" secret_key="$2"

  # Validate MinIO constraints
  if (( ${#access_key} < 3 || ${#access_key} > 20 )); then
    log_error "Access key must be 3–20 chars (was ${#access_key})"; return 1
  fi
  if (( ${#secret_key} < 8 || ${#secret_key} > 40 )); then
    log_error "Secret key must be 8–40 chars (was ${#secret_key})"; return 1
  fi

  log_info "Creating user '$access_key'…"
  retry 5 2 mc admin user add "$MC_ALIAS" "$access_key" "$secret_key"
}


wait_for_user_creation() {
  local user="$1"
  log_info "Waiting for user '$user' to be enabled…"

  local out
  until out="$(mc admin user info "$MC_ALIAS" "$user" --json 2>/dev/null)" && [[ "$out" == *'"userStatus":"enabled"'* ]]; do
    log_info "Still waiting for user to be enabled…"
    sleep 3
  done

  log_info "User '$user' is ready."
}

update_minio(){
  local alias="$1"
  log_info "Updating MinIO client alias '$alias'…"
  retry 5 2 mc admin update "$alias"
  log_success "MinIO client alias '$alias' updated."
}

##################################
# 5) Policy management           #
##################################
write_policy_file() {
  cat > "$1" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS":["*"]},
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": ["arn:aws:s3:::*","arn:aws:s3:::*/*"]
    }
  ]
}
EOF
}

apply_bucket_policy() {
  local user="$1" policy_name="publicread" policy_file="/tmp/public-read.json"
  write_policy_file "$policy_file"

  log_info "Uploading policy '$policy_name'…"
  retry 5 2 mc admin policy create "$MC_ALIAS" "$policy_name" "$policy_file"

  log_info "Attaching policy to user '$user'…"
  retry 5 2 mc admin policy attach "$MC_ALIAS" --user "$user" "$policy_name"

  log_info "Making bucket publicly readable…"
  retry 5 2 mc anonymous set-json "$policy_file" "${MC_ALIAS}/${MINIO_BUCKET}"

  rm -f "$policy_file"
  log_success "Policy applied."
}

##################################
# 6) Test credentials & alias    #
##################################
setup_temporary_alias() {
  local user="$1" secret="$2"
  log_info "Testing new credentials…"
  retry 3 2 mc alias set "$MC_ALIAS_TMP" "$MINIO_ENDPOINT" "$user" "$secret"
  if ! mc ls "${MC_ALIAS_TMP}/${MINIO_BUCKET}" >/dev/null; then
    log_error "New credentials failed to list bucket."
    return 1
  fi
  log_success "New credentials verified."
  mc alias remove "$MC_ALIAS_TMP" || true
}

##################################
# 7) Main orchestration          #
##################################
setup_minio() {
  wait_for_minio "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
  ensure_mc_alias "$MC_ALIAS" "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"  
  ensure_bucket_exists "$MC_ALIAS" "$MINIO_BUCKET"
  #update_minio "$MC_ALIAS"

  # Generate user creds
  read -r access_key secret_key < <(generate_access_keys)
  log_info "Access Key: $access_key"
  log_info "Secret Key: $secret_key"

  create_user_credentials "$access_key" "$secret_key"
  wait_for_user_creation "$access_key"

  apply_bucket_policy "$access_key"
  setup_temporary_alias "$access_key" "$secret_key"

  echo
  log_info "[MINIO CONFIG]"
  log_info "Endpoint: $MINIO_ENDPOINT"
  log_info "Bucket:   $MINIO_BUCKET"
  log_info "Access Key: $access_key"
  log_info "Secret Key: $secret_key"
}

# Export functions if needed
export -f setup_minio
export -f wait_for_minio
export -f ensure_mc_alias
export -f ensure_bucket_exists
export -f create_user_credentials
export -f wait_for_user_creation
export -f apply_bucket_policy
export -f setup_temporary_alias
export -f generate_access_keys
export -f write_policy_file