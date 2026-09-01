#!/usr/bin/env bash
set -euo pipefail

current="$PWD"
readonly ZENODO_URL="https://zenodo.org/records/4968940/files/qpqr_ori_ab1_final.zip?download=1"
readonly ARCHIVE_NAME="qpqr_ori_ab1_final.zip"
readonly ARCHIVE_MD5="25b84a3f8c3ff118fbedef7d55592b1b"

usage() {
  printf 'Usage: %s OUTDIR\n\n' "${0##*/}"
  printf 'Download Zenodo record 4968940, check its MD5, and expand it into OUTDIR.\n'
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

md5_file() {
  local file=$1
  local digest

  if command -v md5sum >/dev/null 2>&1; then
    digest=$(md5sum "$file")
    printf '%s\n' "${digest%% *}"
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$file"
  else
    die 'required command not found: md5sum or md5'
  fi
}

check_md5() {
  local expected=$1
  local file=$2
  local actual

  actual=$(md5_file "$file")
  [[ "$actual" == "$expected" ]] || die "MD5 mismatch for $file: expected $expected, got $actual"
}

safe_unzip() {
  local zip_path=$1
  local dest_dir=$2
  local listing entry

  listing=$(unzip -Z1 "$zip_path") || die "cannot list ZIP entries: $zip_path"
  while IFS= read -r entry; do
    case "$entry" in
      ''|/*|..|../*|*/..|*/../*)
        die "unsafe ZIP entry in $zip_path: $entry"
        ;;
    esac
  done <<< "$listing"

  unzip -q "$zip_path" -d "$dest_dir"
}

move_contents() (
  shopt -s dotglob nullglob
  local source_dir=$1
  local dest_dir=$2
  local entry basename
  local -a entries=("$source_dir"/*)

  ((${#entries[@]} > 0)) || die 'nothing was extracted from archive'
  for entry in "${entries[@]}"; do
    basename=${entry##*/}
    [[ ! -e "$dest_dir/$basename" ]] || die "OUTDIR already contains: $basename"
  done

  mv "${entries[@]}" "$dest_dir"/
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
else
  mkdir -p "$outdir"
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/zenodo-4968940.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

archive="$tmpdir/$ARCHIVE_NAME"
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

check_md5 "$ARCHIVE_MD5" "$archive"
unzip -tq "$archive" >/dev/null
safe_unzip "$archive" "$extract_dir"
rm "$archive"

move_contents "$extract_dir" "$outdir"

## Temporary

cd "$outdir"
git clone https://github.com/garniergere/Reference.Db.SNPs.Quercus/ || cd "$current"
cd "$current"

printf 'Extracted Zenodo record 4968940 to %s\n' "$outdir"
