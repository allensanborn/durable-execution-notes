#!/usr/bin/env bash
# Regenerate every diagram from docs/architecture/workspace.dsl.
#   validate -> export mermaid -> post-process to GitHub-safe mermaid -> render SVG with
#   htmlLabels off -> fail if any <div> leaked into the rendered output.
# Run from the repository root.
set -euo pipefail
W=docs/architecture/workspace.dsl
OUT=docs/architecture/exports
SZ="structurizr/structurizr"

docker run --rm -v "$PWD:/work" -w /work $SZ validate -workspace "$W"
docker run --rm -v "$PWD:/work" -w /work $SZ inspect  -workspace "$W" || true
rm -f "$OUT"/*.mmd
docker run --rm -v "$PWD:/work" -w /work $SZ export -workspace "$W" -format mermaid -output "$OUT"

mkdir -p "$OUT/clean"
echo '{"htmlLabels": false, "flowchart": {"htmlLabels": false}}' > "$OUT/clean/mmdc.json"
for f in "$OUT"/*.mmd; do
  b=$(basename "$f")
  python3 tools/structurizr-mermaid-clean.py "$f" --dash-stroke '#b3591a' --dash-edge '^PROPOSED' > "$OUT/clean/$b"
  docker run --rm -v "$PWD:/data" -u "$(id -u):$(id -g)" minlag/mermaid-cli \
    -i "/data/$OUT/clean/$b" -o "/data/$OUT/clean/${b%.mmd}.svg" -c "/data/$OUT/clean/mmdc.json" >/dev/null
  if grep -q '<div' "$OUT/clean/${b%.mmd}.svg"; then
    echo "FAIL: div leaked into ${b%.mmd}.svg" >&2; exit 1
  fi
  echo "ok  ${b%.mmd}"
done
