#!/usr/bin/env bash
# Build HW6_SUBMISSION.pdf from HW6_SUBMISSION.md (optional pandoc).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MD="${DIR}/HW6_SUBMISSION.md"
OUT="${DIR}/HW6_SUBMISSION.pdf"

if ! [ -f "${MD}" ]; then
  echo "Missing ${MD}" >&2
  exit 1
fi

if command -v pandoc >/dev/null 2>&1; then
  if command -v pdflatex >/dev/null 2>&1; then
    pandoc "${MD}" -o "${OUT}" --pdf-engine=pdflatex -V geometry:margin=1in
  else
    pandoc "${MD}" -o "${OUT}" 2>/dev/null || pandoc "${MD}" -o "${OUT}" --pdf-engine=wkhtmltopdf 2>/dev/null || {
      echo "pandoc could not build PDF (install MacTeX, basictex, or wkhtmltopdf)."
      echo "Alternative: open HW6_SUBMISSION.md in VS Code / Typora / Google Docs and export as PDF."
      exit 1
    }
  fi
  echo "Wrote ${OUT}"
else
  echo "pandoc not found. Install: https://pandoc.org/installing.html"
  echo "Or open ${MD} and use Print / Export to PDF."
  exit 1
fi
