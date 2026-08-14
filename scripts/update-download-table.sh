#!/usr/bin/env bash
# Regenerate the downloads table in README.md and README.ro.md from the GitHub
# releases API. Run it after publishing a release; it rewrites everything
# between the two marker comments and leaves the rest of the file alone.
#
#   ./scripts/update-download-table.sh
#
# The top row points at `latest` rather than a fixed tag, so it stays correct
# even when this has not been run — only the rows below it go stale.
set -euo pipefail

REPO="cremenescu/mRemoteNXT"
ROWS="${1:-6}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

badge() { # tag -> shields URL for that tag's downloads
    printf 'https://img.shields.io/github/downloads/%s/%s/total?label=%s&color=44cc11' \
        "$REPO" "$1" "$(printf '%s' "$1" | sed 's/-alpha//')"
}

build_table() { # $1 = en | ro
    local head_ver head_date h1 h2 h3 latest all
    case "$1" in
        ro) h1="Versiune"; h2="Publicata"; h3="Descarcari"; latest="ultima"; all="Toate versiunile" ;;
        *)  h1="Version";  h2="Released";  h3="Downloads"; latest="latest";  all="All releases" ;;
    esac
    head_ver=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
    head_date=$(gh api "repos/$REPO/releases/latest" --jq '.published_at | split("T")[0]')

    echo "| $h1 | $h2 | $h3 |"
    echo "|---|---|---|"
    printf '| **%s** (%s) | %s | ![](https://img.shields.io/github/downloads/%s/latest/total?label=downloads&color=44cc11) |\n' \
        "$head_ver" "$latest" "$head_date" "$REPO"

    gh api "repos/$REPO/releases?per_page=$((ROWS + 1))" \
        --jq '.[] | "\(.tag_name)\t\(.published_at | split("T")[0])"' \
    | tail -n +2 | head -n "$((ROWS - 1))" \
    | while IFS=$'\t' read -r tag date; do
        printf '| %s | %s | ![](%s) |\n' "$tag" "$date" "$(badge "$tag")"
    done

    printf '| **%s** | | ![](https://img.shields.io/github/downloads/%s/total?label=total&color=44cc11) |\n' "$all" "$REPO"
}

for f in README.md README.ro.md; do
    case "$f" in *.ro.md) LANG_CODE=ro ;; *) LANG_CODE=en ;; esac
    TABLE="$(build_table "$LANG_CODE")"
    python3 - "$ROOT/$f" <<PY
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
start, end = "<!-- downloads:start -->", "<!-- downloads:end -->"
if start not in s:
    sys.exit(f"{p.name}: lipsesc marcajele {start} / {end}")
a = s.index(start) + len(start)
b = s.index(end)
p.write_text(s[:a] + "\n\n" + """$TABLE""" + "\n\n" + s[b:])
print(f"{p.name}: tabel actualizat")
PY
done
