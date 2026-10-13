#!/usr/bin/env bash
#
# Tests aws/deploy_report.sh against a mock "aws" CLI (no AWS account needed).
# The mock records every call so the expected sequence can be checked.

# Variables below are read inside check() via eval.
# shellcheck disable=SC2034

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/data"
cat > "$WORK/bin/aws" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$AWS_CALLS"
case "$1 $2" in
    "s3api head-bucket") [ -f "$BUCKET_EXISTS" ] && exit 0 || exit 254 ;;
    "s3api create-bucket") touch "$BUCKET_EXISTS" ;;
    "s3 cp") cp "$3" "$UPLOADED" ;;
    "s3 rb") rm -f "$BUCKET_EXISTS" ;;
esac
exit 0
MOCK
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"
export AWS_CALLS="$WORK/calls" BUCKET_EXISTS="$WORK/bucket" UPLOADED="$WORK/uploaded.html"
export INVENTORY_DATA_DIR="$WORK/data"
printf 'Item,Category,Quantity,Date Added,Date Removed\nLaptop,electronics,20,2025-01-14 13:12:26,\n' \
    > "$WORK/data/inventory.csv"

PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "  PASS  $1"; else FAIL=$((FAIL+1)); echo "  FAIL  $1"; fi; }

echo "Deploy"
out=$("$ROOT/aws/deploy_report.sh" my-inventory-report ap-south-1 2>&1); code=$?
check "succeeds"                         '[ $code -eq 0 ] && grep -q "Deployed:" <<< "$out"'
check "creates bucket with region constraint" 'grep -q "create-bucket --bucket my-inventory-report --region ap-south-1 --create-bucket-configuration LocationConstraint=ap-south-1" "$AWS_CALLS"'
check "applies public-read policy"       'grep -q "put-bucket-policy --bucket my-inventory-report" "$AWS_CALLS"'
check "enables website hosting"          'grep -q "s3 website s3://my-inventory-report --index-document index.html" "$AWS_CALLS"'
check "uploads the generated report"     'grep -q "<td>Laptop</td>" "$UPLOADED"'
check "prints the website URL"           'grep -q "http://my-inventory-report.s3-website.ap-south-1.amazonaws.com" <<< "$out"'
check "writes a deploy log"              'grep -q "Deployed:" "$WORK/data/deploy.log"'

echo "Redeploy"
: > "$AWS_CALLS"
"$ROOT/aws/deploy_report.sh" my-inventory-report ap-south-1 >/dev/null 2>&1
check "does not recreate existing bucket" '! grep -q "create-bucket" "$AWS_CALLS"'

echo "Region endpoint format"
out=$("$ROOT/aws/deploy_report.sh" other-bucket us-east-1 2>&1)
check "us-east-1 has no LocationConstraint" '! grep -q "LocationConstraint=us-east-1" "$AWS_CALLS"'
check "older region uses dash URL"        'grep -q "s3-website-us-east-1" <<< "$out"'

echo "Validation"
out=$("$ROOT/aws/deploy_report.sh" Bad_Name 2>&1); code=$?
check "rejects invalid bucket name"      '[ $code -ne 0 ] && grep -q "Invalid bucket name" <<< "$out"'
rm "$WORK/data/inventory.csv"
out=$("$ROOT/aws/deploy_report.sh" my-inventory-report 2>&1); code=$?
check "fails clearly without inventory"  '[ $code -ne 0 ] && grep -q "No inventory found" <<< "$out"'

echo "Delete"
out=$("$ROOT/aws/deploy_report.sh" --delete my-inventory-report 2>&1)
check "removes the bucket"               'grep -q "s3 rb s3://my-inventory-report --force" "$AWS_CALLS"'

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
