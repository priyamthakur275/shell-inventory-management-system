#!/usr/bin/env bash
#
# Publish the inventory HTML report as a static website on Amazon S3.
#
# Usage:
#   ./aws/deploy_report.sh <bucket-name> [region]          # create/update the site
#   ./aws/deploy_report.sh --delete <bucket-name> [region] # remove the site and bucket
#
# Requires: AWS CLI v2, configured credentials (aws configure).
# Reads inventory.csv from $INVENTORY_DATA_DIR (default: current directory).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_LOG="${INVENTORY_DATA_DIR:-$PWD}/deploy.log"

log()  { echo "$(date +"%Y-%m-%d %H:%M:%S") [INFO] $*" | tee -a "$DEPLOY_LOG"; }
fail() { echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR] $*" | tee -a "$DEPLOY_LOG" >&2; exit 1; }

usage() {
    echo "Usage: $0 [--delete] <bucket-name> [region]" >&2
    exit 2
}

# S3 website endpoints use "s3-website-<region>" in older regions
# and "s3-website.<region>" in newer ones.
website_url() {
    local bucket="$1" region="$2"
    case "$region" in
        us-east-1|us-west-1|us-west-2|eu-west-1|ap-southeast-1|ap-southeast-2|ap-northeast-1|sa-east-1|us-gov-west-1)
            echo "http://$bucket.s3-website-$region.amazonaws.com" ;;
        *)
            echo "http://$bucket.s3-website.$region.amazonaws.com" ;;
    esac
}

check_prerequisites() {
    command -v aws >/dev/null 2>&1 || fail "AWS CLI not found. Install it: https://aws.amazon.com/cli/"
    aws sts get-caller-identity >/dev/null 2>&1 \
        || fail "AWS credentials are missing or invalid. Run 'aws configure' first."
}

bucket_exists() {
    aws s3api head-bucket --bucket "$1" >/dev/null 2>&1
}

create_bucket() {
    local bucket="$1" region="$2"
    log "Creating bucket s3://$bucket in $region"
    if [ "$region" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
    else
        aws s3api create-bucket --bucket "$bucket" --region "$region" \
            --create-bucket-configuration LocationConstraint="$region" >/dev/null
    fi || fail "Could not create bucket '$bucket'. Bucket names are global; try a more unique name."
}

make_public_website() {
    local bucket="$1"
    log "Allowing public read access for the website"
    aws s3api put-public-access-block --bucket "$bucket" --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false" \
        || fail "Could not update the public access block on '$bucket'."

    aws s3api put-bucket-policy --bucket "$bucket" --policy "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Sid\": \"PublicReadForWebsite\",
        \"Effect\": \"Allow\",
        \"Principal\": \"*\",
        \"Action\": \"s3:GetObject\",
        \"Resource\": \"arn:aws:s3:::$bucket/*\"
      }]
    }" || fail "Could not apply the public-read bucket policy to '$bucket'."

    log "Enabling static website hosting"
    aws s3 website "s3://$bucket" --index-document index.html \
        || fail "Could not enable static website hosting on '$bucket'."
}

deploy() {
    local bucket="$1" region="$2" report

    INVENTORY_FILE="${INVENTORY_DATA_DIR:-$PWD}/inventory.csv"
    [ -f "$INVENTORY_FILE" ] || fail "No inventory found at $INVENTORY_FILE. Run ./inventory.sh and add items first."

    check_prerequisites

    # Reuse the HTML generator from the main script.
    # shellcheck source=../inventory.sh
    source "$SCRIPT_DIR/../inventory.sh"
    report="$(mktemp -d)/index.html"
    write_html_report "$report" || fail "Failed to generate the HTML report."
    log "Generated report from $INVENTORY_FILE"

    bucket_exists "$bucket" || create_bucket "$bucket" "$region"
    make_public_website "$bucket"

    log "Uploading report"
    aws s3 cp "$report" "s3://$bucket/index.html" --content-type "text/html" --cache-control "no-cache" >/dev/null \
        || fail "Upload to s3://$bucket failed."

    log "Deployed: $(website_url "$bucket" "$region")"
}

delete_site() {
    local bucket="$1"
    check_prerequisites
    bucket_exists "$bucket" || fail "Bucket '$bucket' does not exist."
    log "Deleting all objects and bucket s3://$bucket"
    aws s3 rb "s3://$bucket" --force >/dev/null || fail "Could not delete bucket '$bucket'."
    log "Deleted s3://$bucket"
}

main() {
    local mode="deploy"
    if [ "${1:-}" = "--delete" ]; then
        mode="delete"
        shift
    fi
    [ $# -ge 1 ] || usage
    local bucket="$1"
    local region="${2:-${AWS_REGION:-ap-south-1}}"

    [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] \
        || fail "Invalid bucket name '$bucket'. Use 3-63 lowercase letters, numbers, dots or hyphens."

    if [ "$mode" = "delete" ]; then
        delete_site "$bucket"
    else
        deploy "$bucket" "$region"
    fi
}

main "$@"
