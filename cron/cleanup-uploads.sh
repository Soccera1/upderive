#!/bin/bash

UPLOADS_DIR="/var/lib/upderive/uploads"
DAYS_OLD=30

if [ ! -d "$UPLOADS_DIR" ]; then
    echo "Uploads directory does not exist: $UPLOADS_DIR"
    exit 1
fi

echo "Starting cleanup of uploads older than $DAYS_OLD days..."

DELETED=0
KEPT=0

while IFS= read -r -d '' file; do
    DELETED=$((DELETED + 1))
    rm -v "$file"
done < <(find "$UPLOADS_DIR" -type f -mtime +$DAYS_OLD ! -name "*-permanent*" -print0)

echo "Cleanup complete. Deleted: $DELETED files, Kept permanent files: $KEPT"