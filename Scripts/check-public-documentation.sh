#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

forbidden=(
  "ParsingBook"
  "Evidence Grounder"
  "EvidenceGrounder"
  "角色 Parser"
  "数据库坐标"
  "GRDB"
  "手工字段保护"
  "业务 Task DB"
  "TaskDBManager"
  "AICharacterRecognitionTaskManager"
)

status=0
for token in "${forbidden[@]}"; do
  if git -C "$ROOT" grep -n -I -i -F -- "$token" -- \
      '*.md' '*.txt' '*.json' >/tmp/bone-agent-doc-scan.txt; then
    echo "公开说明包含 Host 专有信息：$token" >&2
    cat /tmp/bone-agent-doc-scan.txt >&2
    status=1
  fi
done
rm -f /tmp/bone-agent-doc-scan.txt
exit "$status"
