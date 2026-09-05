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

current_version="$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' \
  "$ROOT/Sources/BoneAgentKit/Compatibility/BoneAgentKitVersion.swift")"
if [[ -z "$current_version" ]]; then
  echo "无法读取 BoneAgentKitVersion.current" >&2
  status=1
fi

required_readme=(
  'https://github.com/taokoplay/BoneAgentKit.git'
  "exact: \"$current_version\""
  '`BoneAgentKit`'
  '`BoneAgentTesting`'
  '`BoneAgentLocalModels`'
  '`BoneAgentLlama`'
  'Documentation/INDEX.md'
  'AGPL-3.0-only'
)

for token in "${required_readme[@]}"; do
  if ! grep -Fq -- "$token" "$ROOT/README.md"; then
    echo "README 缺少必需内容：$token" >&2
    status=1
  fi
done

legacy_alpha9_names=(
  'BoneAgentKit('
  'BoneAgentLocalRuntime'
  'BoneAgentPersistence'
  'BoneInMemoryAgentPersistence'
  'BoneStoredRun'
  'BoneRunCheckpoint'
  'BoneAgentWorkflowStep'
  'BoneInferenceInvocationIdentity'
  'BoneInferenceDetailedStreaming'
  'BoneLlamaCompiledConstraintRuntime'
  'BoneLlamaCompiledGenerationControl'
  'BoneCapabilityVerificationIdentity'
  'BoneLlamaPromptEncoding'
  'BoneLlamaChatMLPromptEncoder'
  'BoneLlamaToolCalling'
  'BoneLlamaJSONToolCallingCodec'
  'BoneCrashTestHarness'
  'BoneLocalRuntimeAdapter'
)

for token in "${legacy_alpha9_names[@]}"; do
  if git -C "$ROOT" grep -n -I -F -- "$token" -- \
      'README.md' 'Examples/*.md' 'Examples/**/*.md' 'Documentation/*.md' \
      ':!Documentation/Plans/**' >/tmp/bone-agent-alpha9-name-scan.txt; then
    echo "当前公开说明仍包含 Alpha.9 旧名称：$token" >&2
    cat /tmp/bone-agent-alpha9-name-scan.txt >&2
    status=1
  fi
done
rm -f /tmp/bone-agent-alpha9-name-scan.txt

python3 - "$ROOT" <<'PY' || status=1
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

root = Path(sys.argv[1])
tracked = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "*.md"], text=True
).splitlines()
errors: list[str] = []
version_source = (root / "Sources/BoneAgentKit/Compatibility/BoneAgentKitVersion.swift").read_text()
version = re.search(r'public static let current = "([^"\n]+)"', version_source)
if version is None:
    errors.append("Version source missing current")
elif f'exact: "{version.group(1)}"' not in (root / "README.md").read_text():
    errors.append("README exact version differs from BoneAgentKitVersion.current")
link_pattern = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")

for relative in tracked:
    path = root / relative
    text = path.read_text(encoding="utf-8")
    headings = []
    fenced = False
    for line_number, line in enumerate(text.splitlines(), 1):
        if line.startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        match = re.match(r"^(#{1,6})\s+", line)
        if match:
            headings.append((line_number, len(match.group(1))))

    h1_count = sum(level == 1 for _, level in headings)
    if h1_count != 1:
        errors.append(f"{relative}: 需要且只能有一个一级标题，实际 {h1_count}")
    for (previous_line, previous), (line_number, current) in zip(headings, headings[1:]):
        if current > previous + 1:
            errors.append(
                f"{relative}:{line_number}: 标题从 H{previous} 跳到 H{current}"
            )

    for target in link_pattern.findall(text):
        target = target.strip().split()[0].strip("<>")
        if not target or target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        file_part = unquote(target.split("#", 1)[0])
        if not file_part:
            continue
        destination = (path.parent / file_part).resolve()
        try:
            destination.relative_to(root.resolve())
        except ValueError:
            errors.append(f"{relative}: 链接越出仓库：{target}")
            continue
        if not destination.exists():
            errors.append(f"{relative}: 相对链接目标不存在：{target}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY

exit "$status"
