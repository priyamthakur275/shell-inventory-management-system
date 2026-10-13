#!/usr/bin/env bash
#
# Inventory Management System
# A Bash + Zenity GUI tool for managing a CSV-based inventory on UNIX/Linux.
#
# Data format (inventory.csv):
#   Item,Category,Quantity,Date Added,Date Removed
#
# Works on Linux and macOS (Bash 3.2+). Requires: zenity, awk, grep, date.

set -u

# ---------------------------------------------------------------------------
# 1. Setup: file paths
# ---------------------------------------------------------------------------
DATA_DIR="${INVENTORY_DATA_DIR:-$PWD}"
INVENTORY_FILE="$DATA_DIR/inventory.csv"
BACKUP_FILE="$DATA_DIR/inventory_backup.csv"
LOG_FILE="$DATA_DIR/inventory.log"
ERROR_LOG="$DATA_DIR/inventory_error.log"
HEADER="Item,Category,Quantity,Date Added,Date Removed"

# ---------------------------------------------------------------------------
# 2. Utility functions
# ---------------------------------------------------------------------------
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# Record a significant action in the action log.
log_action() { echo "$(timestamp) [INFO] $*" >> "$LOG_FILE"; }

# Record an error in the error log and show it to the user.
log_error() {
    echo "$(timestamp) [ERROR] $*" >> "$ERROR_LOG"
    zenity --error --text="$*" 2>/dev/null
}

# Create the inventory, log and error files if they do not already exist.
initialize_inventory() {
    if ! command -v zenity >/dev/null 2>&1; then
        echo "Error: zenity is not installed. Install it first (see README)." >&2
        exit 1
    fi
    mkdir -p "$DATA_DIR"
    [ -f "$INVENTORY_FILE" ] || echo "$HEADER" > "$INVENTORY_FILE"
    touch "$LOG_FILE" "$ERROR_LOG"
    log_action "Session started (inventory: $INVENTORY_FILE)"
}

# Point all file paths at a new inventory file.
set_inventory_file() {
    INVENTORY_FILE="$1"
    BACKUP_FILE="${1%.csv}_backup.csv"
}

# Reject empty values and commas (a comma would break the CSV columns).
valid_text() {
    case "$1" in
        "" | *,*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_quantity() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Exact, case-insensitive match on the Item column.
# awk compares the field as plain text, so names containing regex characters
# (for example "c++ book" or "a.b") are matched literally.
item_exists() {
    awk -F',' -v item="$1" 'NR > 1 && tolower($1) == tolower(item) { found = 1 } END { exit !found }' \
        "$INVENTORY_FILE"
}

get_item_row() {
    awk -F',' -v item="$1" 'NR > 1 && tolower($1) == tolower(item) { print; exit }' "$INVENTORY_FILE"
}

# Rewrite the file through a temp file instead of "sed -i", whose syntax
# differs between GNU (Linux) and BSD (macOS) sed.
replace_inventory() {
    local tmp
    tmp=$(mktemp) || { log_error "Could not create a temporary file."; return 1; }
    if cat > "$tmp" && mv "$tmp" "$INVENTORY_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    log_error "Failed to write $INVENTORY_FILE."
    return 1
}

backup_inventory() {
    if cp "$INVENTORY_FILE" "$BACKUP_FILE"; then
        log_action "Backup created: $BACKUP_FILE"
        return 0
    fi
    log_error "Backup failed for $INVENTORY_FILE."
    return 1
}

restore_backup() {
    if [ ! -f "$BACKUP_FILE" ]; then
        log_error "No backup file found to restore."
        return
    fi
    if cp "$BACKUP_FILE" "$INVENTORY_FILE"; then
        log_action "Inventory restored from $BACKUP_FILE"
        zenity --info --text="Inventory restored from backup successfully."
    else
        log_error "Restore from $BACKUP_FILE failed."
    fi
}

# ---------------------------------------------------------------------------
# 3. Inventory operations
# ---------------------------------------------------------------------------
create_new_file() {
    local file
    file=$(zenity --file-selection --save --confirm-overwrite \
        --title="Create New Inventory File" --filename="new_inventory.csv") || return
    [ -z "$file" ] && return
    case "$file" in *.csv) ;; *) file="$file.csv" ;; esac
    if echo "$HEADER" > "$file"; then
        set_inventory_file "$file"
        log_action "Created new inventory file: $file"
        zenity --info --text="New inventory file created: $file"
    else
        log_error "Could not create $file."
    fi
}

add_item() {
    local item category quantity
    item=$(zenity --entry --title="Add Item" --text="Enter item name:") || return
    if ! valid_text "$item"; then
        log_error "Item name must not be empty or contain commas."
        return
    fi
    if item_exists "$item"; then
        log_error "Item '$item' already exists."
        return
    fi

    category=$(zenity --entry --title="Add Category" --text="Enter category:") || return
    if ! valid_text "$category"; then
        log_error "Category must not be empty or contain commas."
        return
    fi

    quantity=$(zenity --entry --title="Add Quantity" --text="Enter quantity (positive integer):") || return
    if ! valid_quantity "$quantity"; then
        log_error "Invalid quantity '$quantity'. Must be a positive integer."
        return
    fi

    if echo "$item,$category,$quantity,$(timestamp)," >> "$INVENTORY_FILE"; then
        log_action "Added item '$item' (category=$category, quantity=$quantity)"
        zenity --info --text="Item '$item' added successfully."
        backup_inventory
    else
        log_error "Failed to add '$item' to $INVENTORY_FILE."
    fi
}

update_item() {
    local item row old_category old_quantity category quantity
    item=$(zenity --entry --title="Update Item" --text="Enter item name to update:") || return
    [ -z "$item" ] && return
    if ! item_exists "$item"; then
        log_error "Item '$item' not found in inventory."
        return
    fi

    row=$(get_item_row "$item")
    old_category=$(echo "$row" | cut -d',' -f2)
    old_quantity=$(echo "$row" | cut -d',' -f3)

    category=$(zenity --entry --title="Update Category" \
        --text="Enter new category (leave blank to keep '$old_category'):") || return
    [ -z "$category" ] && category="$old_category"
    if ! valid_text "$category"; then
        log_error "Category must not contain commas."
        return
    fi

    quantity=$(zenity --entry --title="Update Quantity" \
        --text="Enter new quantity (leave blank to keep $old_quantity):") || return
    [ -z "$quantity" ] && quantity="$old_quantity"
    if ! valid_quantity "$quantity"; then
        log_error "Invalid quantity '$quantity'. Must be a positive integer."
        return
    fi

    if awk -F',' -v OFS=',' -v item="$item" -v cat="$category" -v qty="$quantity" \
        'NR > 1 && tolower($1) == tolower(item) { $2 = cat; $3 = qty } { print }' \
        "$INVENTORY_FILE" | replace_inventory; then
        log_action "Updated '$item': category $old_category -> $category, quantity $old_quantity -> $quantity"
        zenity --info --text="Item '$item' updated successfully."
        backup_inventory
    fi
}

remove_item() {
    local item
    item=$(zenity --entry --title="Remove Item" --text="Enter the name of the item to remove:") || return
    [ -z "$item" ] && return
    if ! item_exists "$item"; then
        log_error "Item '$item' not found in inventory."
        return
    fi

    if awk -F',' -v item="$item" 'NR == 1 || tolower($1) != tolower(item)' \
        "$INVENTORY_FILE" | replace_inventory; then
        log_action "Removed item '$item' at $(timestamp)"
        zenity --info --text="Item '$item' removed successfully."
        backup_inventory
    fi
}

search_item() {
    local item row
    item=$(zenity --entry --title="Search Item" --text="Enter item name to search:") || return
    [ -z "$item" ] && return
    row=$(get_item_row "$item")
    if [ -z "$row" ]; then
        log_error "Item '$item' not found in inventory."
    else
        zenity --info --title="Search Result" --text="$HEADER\n$row"
    fi
}

# ---------------------------------------------------------------------------
# 4. Reporting and exporting
# ---------------------------------------------------------------------------
view_inventory() {
    if [ ! -f "$INVENTORY_FILE" ]; then
        log_error "No inventory file found."
        return
    fi
    zenity --text-info --title="Inventory Contents" --filename="$INVENTORY_FILE" --width=600 --height=400
}

# Prints: total_items unique_categories total_quantity
compute_analytics() {
    awk -F',' 'NR > 1 && NF >= 3 {
        items++; qty += $3
        cat = tolower($2); if (!(cat in seen)) { seen[cat] = 1; cats++ }
    } END { printf "%d %d %d\n", items, cats, qty }' "$INVENTORY_FILE"
}

generate_analytics() {
    local items cats qty
    read -r items cats qty <<< "$(compute_analytics)"
    log_action "Generated analytics: items=$items categories=$cats quantity=$qty"
    zenity --info --title="Inventory Analytics" \
        --text="Total Items: $items\nUnique Categories: $cats\nTotal Quantity: $qty"
}

# Writes the inventory as an HTML table to the given path.
write_html_report() {
    awk -F',' -v generated="$(timestamp)" '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    BEGIN {
        print "<!DOCTYPE html>"
        print "<html><head><meta charset=\"utf-8\"><title>Inventory Report</title>"
        print "<style>body{font-family:sans-serif;margin:24px}table{border-collapse:collapse}"
        print "th,td{border:1px solid #999;padding:6px 10px;text-align:left}th{background:#eee}</style>"
        print "</head><body><h1>Inventory Report</h1>"
        print "<p>Generated: " generated "</p><table>"
    }
    NR == 1 { print "<tr>"; for (i = 1; i <= NF; i++) print "<th>" esc($i) "</th>"; print "</tr>"; next }
    { print "<tr>"; for (i = 1; i <= 5; i++) print "<td>" esc($i) "</td>"; print "</tr>" }
    END { print "</table></body></html>" }' "$INVENTORY_FILE" > "$1"
}

export_to_html() {
    local export_file
    export_file=$(zenity --file-selection --save --confirm-overwrite \
        --title="Export Inventory as HTML" --filename="inventory.html") || return
    [ -z "$export_file" ] && return
    case "$export_file" in *.html) ;; *) export_file="$export_file.html" ;; esac
    if write_html_report "$export_file"; then
        log_action "Exported inventory to HTML: $export_file"
        zenity --info --text="Inventory exported to HTML successfully: $export_file"
    else
        log_error "Failed to export inventory to $export_file."
    fi
}

# ---------------------------------------------------------------------------
# 5. Main menu
# ---------------------------------------------------------------------------
main_menu() {
    local action
    while true; do
        action=$(zenity --list --title="Inventory Management" --text="Select an action:" \
            --column="Action" --width=350 --height=450 \
            "Create New File" "Add Item" "Update Item" "Remove Item" "Search Item" \
            "View Inventory" "Generate Analytics" "Export to HTML" \
            "Backup Inventory" "Restore Backup" "Exit") || { log_action "Session ended"; exit 0; }

        case "$action" in
            "Create New File")    create_new_file ;;
            "Add Item")           add_item ;;
            "Update Item")        update_item ;;
            "Remove Item")        remove_item ;;
            "Search Item")        search_item ;;
            "View Inventory")     view_inventory ;;
            "Generate Analytics") generate_analytics ;;
            "Export to HTML")     export_to_html ;;
            "Backup Inventory")
                backup_inventory && zenity --info --text="Backup created successfully as '$BACKUP_FILE'." ;;
            "Restore Backup")     restore_backup ;;
            "Exit")               log_action "Session ended"; exit 0 ;;
            *)                    log_error "Invalid option: '$action'" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 6. Initialization and execution
# ---------------------------------------------------------------------------
# Only run the GUI when executed directly, so tests can source the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    initialize_inventory
    main_menu
fi
