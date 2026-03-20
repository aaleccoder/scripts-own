#!/usr/bin/env bash
#
# Create a 24px version of a cursor theme (Xcursor) or resize image cursors.
#
# Usage:
#   ./resize_theme_24.sh [source_dir] [output_dir]
#
# Examples:
#   ./resize_theme_24.sh . ./MacOS-TahoeX-Cursor_24
#   ./resize_theme_24.sh /path/to/theme
#
set -euo pipefail

TARGET_SIZE=24

SOURCE_DIR="${1:-.}"

if [[ "${2-}" != "" ]]; then
  OUTPUT_DIR="$2"
else
  base="$(basename "$(cd "$SOURCE_DIR" 2>/dev/null && pwd || echo "$SOURCE_DIR")")"
  [[ "$base" == "." || "$base" == "/" || "$base" == "" ]] && base="theme"
  OUTPUT_DIR="./${base}_${TARGET_SIZE}"
fi

have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "Error: $*" >&2; exit 1; }

IM_CMD=""
if have magick; then
  IM_CMD="magick"
elif have convert; then
  IM_CMD="convert"
else
  die "ImageMagick is not installed. Install it and re-run."
fi

resize_to_target_png() {
  local input="$1"
  local output="$2"

  mkdir -p "$(dirname "$output")"
  "$IM_CMD" "$input" \
    -background none \
    -resize "${TARGET_SIZE}x${TARGET_SIZE}" \
    -gravity center \
    -extent "${TARGET_SIZE}x${TARGET_SIZE}" \
    "$output"
}

pick_best_source_size() {
  # Pick the size closest to TARGET_SIZE, prefer larger on ties.
  # Reads sizes from stdin (one per line), prints the chosen size.
  awk -v target="$TARGET_SIZE" '
    BEGIN { best=-1; bestd=1e9; }
    /^[0-9]+$/ {
      s=$1; d=s-target; if (d<0) d=-d;
      if (d<bestd || (d==bestd && s>best)) { best=s; bestd=d; }
    }
    END { if (best<0) exit 1; print best; }
  '
}

convert_xcursor_to_24() {
  local cursor_path="$1"
  local out_cursor_path="$2"
  local cursor_name
  cursor_name="$(basename "$cursor_path")"

  have xcur2png || die "Missing 'xcur2png'. Install it (package often named 'xcur2png') and re-run."
  have xcursorgen || die "Missing 'xcursorgen'. Install it (package often named 'xcursorgen' or part of 'x11-apps') and re-run."

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local png_dir conf_path new_png_dir new_conf
  png_dir="$tmp/pngs"
  conf_path="$tmp/${cursor_name}.conf"
  new_png_dir="$tmp/pngs_${TARGET_SIZE}"
  new_conf="$tmp/${cursor_name}_${TARGET_SIZE}.conf"

  mkdir -p "$png_dir" "$new_png_dir"

  # Extract PNGs + config from the Xcursor file.
  xcur2png -d "$png_dir" -c "$conf_path" "$cursor_path" >/dev/null
  [[ -s "$conf_path" ]] || die "xcur2png did not produce a config for: $cursor_name"

  local source_size
  source_size="$(awk '{print $1}' "$conf_path" | sort -n | uniq | pick_best_source_size)"

  local frame=0
  : >"$new_conf"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Expected: <size> <xhot> <yhot> <filename> [<ms-delay>]
    # Keep only the chosen source size block.
    local size xhot yhot filename delay
    size="$(awk '{print $1}' <<<"$line")"
    [[ "$size" == "$source_size" ]] || continue

    xhot="$(awk '{print $2}' <<<"$line")"
    yhot="$(awk '{print $3}' <<<"$line")"
    filename="$(awk '{print $4}' <<<"$line")"
    delay="$(awk '{print $5}' <<<"$line" 2>/dev/null || true)"

    frame=$((frame + 1))
    local in_png out_png out_name
    if [[ "$filename" == /* ]]; then
      in_png="$filename"
    else
      in_png="$png_dir/$filename"
    fi
    out_name="$(printf '%s_%03d.png' "$cursor_name" "$frame")"
    out_png="$new_png_dir/$out_name"

    [[ -f "$in_png" ]] || die "Missing extracted PNG '$filename' for: $cursor_name"
    resize_to_target_png "$in_png" "$out_png"

    local new_xhot new_yhot
    new_xhot="$(awk -v v="$xhot" -v src="$source_size" -v dst="$TARGET_SIZE" 'BEGIN{printf "%d", int((v*dst/src)+0.5)}')"
    new_yhot="$(awk -v v="$yhot" -v src="$source_size" -v dst="$TARGET_SIZE" 'BEGIN{printf "%d", int((v*dst/src)+0.5)}')"

    if [[ -n "${delay:-}" && "$delay" =~ ^[0-9]+$ ]]; then
      printf "%s %s %s %s %s\n" "$TARGET_SIZE" "$new_xhot" "$new_yhot" "$out_name" "$delay" >>"$new_conf"
    else
      printf "%s %s %s %s\n" "$TARGET_SIZE" "$new_xhot" "$new_yhot" "$out_name" >>"$new_conf"
    fi
  done <"$conf_path"

  [[ "$frame" -gt 0 ]] || die "No frames found for $cursor_name (source size chosen: $source_size)."

  mkdir -p "$(dirname "$out_cursor_path")"
  xcursorgen -p "$new_png_dir" "$new_conf" "$out_cursor_path" >/dev/null
}

is_xcursor_file() {
  local path="$1"
  file -b "$path" 2>/dev/null | grep -q "Xcursor data"
}

mkdir -p "$OUTPUT_DIR"

if [[ -d "$SOURCE_DIR/cursors" ]]; then
  # Theme mode: create a new theme directory with a resized 'cursors/'.
  mkdir -p "$OUTPUT_DIR/cursors"

  # Copy top-level theme metadata (leave existing files untouched if they already exist).
  for f in "$SOURCE_DIR"/*; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == "cursors" ]] && continue
    [[ "$(basename "$f")" == "$(basename "$OUTPUT_DIR")" ]] && continue
    if [[ -f "$f" ]]; then
      cp -f "$f" "$OUTPUT_DIR/"
    fi
  done

  count=0
  failed=0

  while IFS= read -r -d '' cursor; do
    rel="${cursor#"$SOURCE_DIR/"}"
    out="$OUTPUT_DIR/${rel}"
    echo "Resizing: ${rel} → ${TARGET_SIZE}px..."

    if is_xcursor_file "$cursor"; then
      if convert_xcursor_to_24 "$cursor" "$out"; then
        count=$((count + 1))
      else
        failed=$((failed + 1))
      fi
    else
      echo "  Skipping (not Xcursor): ${rel}"
    fi
  done < <(find "$SOURCE_DIR/cursors" -type f -print0)

  echo ""
  echo "Done! Created ${count} cursor(s) at ${TARGET_SIZE}px."
  echo "Output directory: $OUTPUT_DIR"
  [[ "$failed" -eq 0 ]] || echo "Failed: $failed"
else
  # Image mode: recursively resize PNG/SVG/CUR files to 24x24 PNGs.
  count=0
  failed=0

  while IFS= read -r -d '' img; do
    rel="${img#"$SOURCE_DIR"/}"
    out_rel="${rel%.*}.png"
    out="$OUTPUT_DIR/$out_rel"

    echo "Resizing: ${rel} → ${TARGET_SIZE}x${TARGET_SIZE}..."
    if resize_to_target_png "$img" "$out"; then
      count=$((count + 1))
      echo "  ✓ Created: $out"
    else
      failed=$((failed + 1))
      echo "  ✗ Failed: $rel"
    fi
  done < <(
    find "$SOURCE_DIR" \
      -path "$OUTPUT_DIR" -prune -o \
      -type f \( -iname "*.png" -o -iname "*.svg" -o -iname "*.cur" \) -print0
  )

  echo ""
  echo "Done! Resized $count image cursor(s) to ${TARGET_SIZE}px."
  echo "Output directory: $OUTPUT_DIR"
  [[ "$failed" -eq 0 ]] || echo "Failed: $failed"
fi
