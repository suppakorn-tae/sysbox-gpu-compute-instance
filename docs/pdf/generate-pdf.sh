#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="$(dirname "$SCRIPT_DIR")"
CSS_FILE="$SCRIPT_DIR/style.css"

CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME_BIN" ]]; then
  echo "Error: Google Chrome not found at $CHROME_BIN" >&2
  exit 1
fi

if ! command -v pandoc >/dev/null 2>&1; then
  echo "Error: pandoc is required but not installed." >&2
  exit 1
fi

convert_to_pdf() {
  local md_file="$1"
  local output_pdf="$2"
  local title="$3"
  local temp_html="$SCRIPT_DIR/.temp_$(basename "$md_file" .md).html"

  echo "==> Converting $(basename "$md_file") -> $(basename "$output_pdf")"

  # Convert Markdown to self-contained HTML with embedded CSS
  pandoc "$md_file" \
    --standalone \
    --css="$CSS_FILE" \
    --metadata title="$title" \
    -o "$temp_html"

  # Print to PDF via Headless Chrome
  "$CHROME_BIN" \
    --headless=new \
    --disable-gpu \
    --no-pdf-header-footer \
    --print-to-pdf="$output_pdf" \
    "$temp_html" >/dev/null 2>&1

  rm -f "$temp_html"
  echo "    Generated: $output_pdf ($(du -h "$output_pdf" | cut -f1))"
}

# Generate PDF for main.md
convert_to_pdf \
  "$DOCS_DIR/main.md" \
  "$SCRIPT_DIR/main.pdf" \
  "Compute Instance Documentation"

# Generate PDF for security-testing.md
convert_to_pdf \
  "$DOCS_DIR/security-testing.md" \
  "$SCRIPT_DIR/security-testing.pdf" \
  "Security Testing Notes"

echo "==> PDF generation complete in $SCRIPT_DIR"
