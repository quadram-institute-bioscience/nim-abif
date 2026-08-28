#!/usr/bin/env bash
set -euo pipefail

readonly ZENODO_URL="https://zenodo.org/api/records/5865470/files-archive"
readonly MUTATION_ZIP="ab1_with_mutation.zip"
readonly NO_MUTATION_ZIP="ab1_with_no_mutation.zip"
readonly MUTATION_ZIP_MD5="e27078216c1320f17f67c7c572210643"
readonly NO_MUTATION_ZIP_MD5="401a21f74892d6d12c3407ee2a21d948"

usage() {
  printf 'Usage: %s OUTDIR\n\n' "${0##*/}"
  printf 'Download Zenodo record 5865470 and expand it into OUTDIR.\n'
  printf 'OUTDIR must be absent or empty. Nested ZIPs are expanded into:\n'
  printf '  OUTDIR/mutation\n'
  printf '  OUTDIR/no_mutation\n'
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

directory_is_empty() (
  shopt -s dotglob nullglob
  local -a entries=("$1"/*)
  ((${#entries[@]} == 0))
)

count_ab1() (
  shopt -s nullglob
  local -a files=("$1"/*.ab1)
  printf '%s\n' "${#files[@]}"
)

md5_file() {
  local file=$1
  local digest

  if command -v md5sum >/dev/null 2>&1; then
    digest=$(md5sum "$file")
    printf '%s\n' "${digest%% *}"
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$file"
  else
    return 1
  fi
}

check_md5() {
  local expected=$1
  local file=$2
  local actual

  if ! actual=$(md5_file "$file"); then
    printf 'Skipping MD5 check for %s: no md5/md5sum command found\n' "$file" >&2
    return 0
  fi

  [[ "$actual" == "$expected" ]] || die "MD5 mismatch for $file: expected $expected, got $actual"
}

safe_unzip() {
  local zip_path=$1
  local dest_dir=$2
  local listing entry

  listing=$(unzip -Z1 "$zip_path") || die "cannot list ZIP entries: $zip_path"
  while IFS= read -r entry; do
    case "$entry" in
      ''|/*|../*|*/../*)
        die "unsafe ZIP entry in $zip_path: $entry"
        ;;
    esac
  done <<< "$listing"

  unzip -q "$zip_path" -d "$dest_dir"
}

move_contents() (
  shopt -s dotglob nullglob
  local -a entries=("$1"/*)
  ((${#entries[@]} > 0)) || die "nothing was extracted from archive"
  mv "${entries[@]}" "$2"/
)

arg=${1:-}

if [[ $# -ne 1 || "$arg" == "-h" || "$arg" == "--help" ]]; then
  usage
  if [[ $# -eq 1 && ("$arg" == "-h" || "$arg" == "--help") ]]; then
    exit 0
  fi
  exit 1
fi

outdir=$arg

require_command curl
require_command mktemp
require_command unzip

if [[ -e "$outdir" ]]; then
  [[ -d "$outdir" ]] || die "OUTDIR exists and is not a directory: $outdir"
  directory_is_empty "$outdir" || die "OUTDIR exists and is not empty: $outdir"
else
  mkdir -p "$outdir"
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/zenodo-5865470.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

archive="$tmpdir/5865470.zip"
extract_dir="$tmpdir/extract"
mkdir "$extract_dir"

printf 'Downloading %s\n' "$ZENODO_URL"
curl \
  --fail \
  --location \
  --show-error \
  --silent \
  --retry 3 \
  --retry-delay 2 \
  --output "$archive" \
  --write-out 'Saved archive from %{url_effective} (%{http_code}, %{content_type}, %{size_download} bytes)\n' \
  "$ZENODO_URL"

unzip -tq "$archive" >/dev/null
safe_unzip "$archive" "$extract_dir"

[[ -f "$extract_dir/$MUTATION_ZIP" ]] || die "missing nested ZIP: $MUTATION_ZIP"
[[ -f "$extract_dir/$NO_MUTATION_ZIP" ]] || die "missing nested ZIP: $NO_MUTATION_ZIP"

check_md5 "$MUTATION_ZIP_MD5" "$extract_dir/$MUTATION_ZIP"
check_md5 "$NO_MUTATION_ZIP_MD5" "$extract_dir/$NO_MUTATION_ZIP"

mkdir "$extract_dir/mutation" "$extract_dir/no_mutation"
safe_unzip "$extract_dir/$MUTATION_ZIP" "$extract_dir/mutation"
safe_unzip "$extract_dir/$NO_MUTATION_ZIP" "$extract_dir/no_mutation"
rm "$extract_dir/$MUTATION_ZIP" "$extract_dir/$NO_MUTATION_ZIP"

top_level_count=$(count_ab1 "$extract_dir")
mutation_count=$(count_ab1 "$extract_dir/mutation")
no_mutation_count=$(count_ab1 "$extract_dir/no_mutation")

[[ "$top_level_count" == "20" ]] || die "expected 20 top-level AB1 files, found $top_level_count"
[[ "$mutation_count" == "12" ]] || die "expected 12 mutation AB1 files, found $mutation_count"
[[ "$no_mutation_count" == "20" ]] || die "expected 20 no_mutation AB1 files, found $no_mutation_count"

move_contents "$extract_dir" "$outdir"

printf 'Extracted Zenodo record 5865470 to %s\n' "$outdir"
printf 'AB1 files: %s top-level, %s mutation, %s no_mutation\n' \
  "$top_level_count" "$mutation_count" "$no_mutation_count"
