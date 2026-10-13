#!/usr/bin/env bash
#
# Headless tests for inventory.sh.
# A mock "zenity" placed first on PATH replays scripted answers from a queue
# file and records every dialog, so the real GUI is never opened.
#
# Usage: bash tests/run_tests.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/zenity" <<'MOCK'
#!/usr/bin/env bash
# Record the dialog type and its text.
echo "$*" >> "$ZENITY_LOG"
case "$1" in
    --info|--error|--text-info) exit 0 ;;
esac
# Input dialogs: pop the next scripted answer.
answer=$(head -n 1 "$ZENITY_QUEUE")
tail -n +2 "$ZENITY_QUEUE" > "$ZENITY_QUEUE.tmp" && mv "$ZENITY_QUEUE.tmp" "$ZENITY_QUEUE"
[ "$answer" = "__CANCEL__" ] && exit 1
echo "$answer"
MOCK
chmod +x "$WORK/bin/zenity"

export PATH="$WORK/bin:$PATH"
export ZENITY_LOG="$WORK/zenity.log"
export ZENITY_QUEUE="$WORK/queue"
export INVENTORY_DATA_DIR="$WORK/data"

PASS=0
FAIL=0
check() {
    if eval "$2"; then
        PASS=$((PASS + 1)); echo "  PASS  $1"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL  $1"
    fi
}
answers() { printf '%s\n' "$@" > "$ZENITY_QUEUE"; : > "$ZENITY_LOG"; }

# shellcheck source=../inventory.sh
source "$ROOT/inventory.sh"
initialize_inventory

echo "Initialization"
check "creates inventory with header" '[ "$(head -n 1 "$INVENTORY_FILE")" = "$HEADER" ]'
check "creates log files"             '[ -f "$LOG_FILE" ] && [ -f "$ERROR_LOG" ]'

echo "Add item"
answers "Laptop" "electronics" "20"; add_item
answers "Apple" "fruits" "50"; add_item
answers "c++ book" "books" "5"; add_item
check "adds three items"              '[ "$(tail -n +2 "$INVENTORY_FILE" | wc -l | tr -d " ")" = 3 ]'
check "creates backup after add"      '[ -f "$BACKUP_FILE" ]'
check "logs the add action"           'grep -q "Added item .Laptop." "$LOG_FILE"'

echo "Validation"
answers "laptop"; add_item
check "rejects duplicate (case-insensitive)" 'grep -q "already exists" "$ERROR_LOG"'
answers "Mango" "fruits" "-3"; add_item
check "rejects negative quantity"     'grep -q "Invalid quantity .-3." "$ERROR_LOG"'
answers "Mango" "fruits" "abc"; add_item
check "rejects non-numeric quantity"  'grep -q "Invalid quantity .abc." "$ERROR_LOG"'
answers "Bad,Name"; add_item
check "rejects comma in item name"    'grep -q "must not be empty or contain commas" "$ERROR_LOG"'
check "invalid input adds nothing"    '[ "$(tail -n +2 "$INVENTORY_FILE" | wc -l | tr -d " ")" = 3 ]'

echo "Update item"
answers "apple" "" "75"; update_item
check "blank category keeps old value" 'grep -q "^Apple,fruits,75," "$INVENTORY_FILE"'
answers "Laptop" "computers" ""; update_item
check "blank quantity keeps old value" 'grep -q "^Laptop,computers,20," "$INVENTORY_FILE"'
answers "Ghost"; update_item
check "update of missing item is logged" 'grep -q "Item .Ghost. not found" "$ERROR_LOG"'

echo "Search and remove (special characters)"
answers "C++ BOOK"; search_item
check "finds name with regex characters" 'grep -q "c++ book,books,5" "$ZENITY_LOG"'
answers "C++ BOOK"; remove_item
check "removes name with regex characters" '! grep -q "^c++ book," "$INVENTORY_FILE"'
check "remove keeps other rows"       '[ "$(tail -n +2 "$INVENTORY_FILE" | wc -l | tr -d " ")" = 2 ]'

echo "Analytics"
answers "Banana" "Fruits" "5"; add_item
check "counts items, categories (case-insensitive), quantity" '[ "$(compute_analytics)" = "3 2 100" ]'

echo "HTML export"
write_html_report "$WORK/report.html"
check "writes an HTML table"          'grep -q "<td>Banana</td>" "$WORK/report.html"'
answers "<b>tag" "misc" "1"; add_item
write_html_report "$WORK/report.html"
check "escapes HTML special characters" 'grep -q "&lt;b&gt;tag" "$WORK/report.html"'

echo "Backup and restore"
backup_inventory
cp "$INVENTORY_FILE" "$WORK/expected.csv"
echo "Corrupted,row" >> "$INVENTORY_FILE"   # simulate an unwanted change
restore_backup
check "restore brings back the backup" 'cmp -s "$INVENTORY_FILE" "$WORK/expected.csv"'
rm -f "$BACKUP_FILE"; : > "$ERROR_LOG"
restore_backup
check "restore without backup is an error" 'grep -q "No backup file found" "$ERROR_LOG"'

echo "Cancel handling"
answers "__CANCEL__"; cp "$INVENTORY_FILE" "$WORK/before.csv"; add_item
check "cancelling a dialog changes nothing" 'cmp -s "$INVENTORY_FILE" "$WORK/before.csv"'

echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
