#!/usr/bin/env bash
set -euo pipefail

# 用法：bash Scripts/check-resource-demo.sh [报告父目录]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/Examples/ResourceReadingDemo"
BUILD="${BONE_DEMO_BUILD_DIR:-$EXAMPLE/.build}"
if [[ $# -gt 1 ]]; then
  echo '用法：bash Scripts/check-resource-demo.sh [报告父目录]' >&2
  exit 64
fi
REPORT_PARENT="${1:-${PI_SCRATCH_DIR:-${TMPDIR:-/tmp}}}"
mkdir -p "$REPORT_PARENT"
REPORT_DIR="$(mktemp -d "$REPORT_PARENT/resource-demo.XXXXXX")"
RUN_ARGS=(--package-path "$EXAMPLE" --scratch-path "$BUILD" -j 4
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)
VERIFY="$ROOT/Scripts/verify-resource-demo.py"

printf '构建并运行离线 Demo；报告目录：%s\n' "$REPORT_DIR"
if ! swift run "${RUN_ARGS[@]}" ResourceReadingDemo --self-test --json > "$REPORT_DIR/suite.json" 2> "$REPORT_DIR/build.log"; then
  tail -n 30 "$REPORT_DIR/build.log" >&2
  echo "FAIL: Demo 构建或运行失败，请查看 $REPORT_DIR" >&2
  exit 1
fi
python3 "$VERIFY" "$REPORT_DIR/suite.json"

run_demo() { swift run --skip-build "${RUN_ARGS[@]}" ResourceReadingDemo "$@"; }
expect_exit() {
  local expected="$1" name="$2" code=0
  shift 2
  run_demo "$@" > "$REPORT_DIR/$name.json" 2> "$REPORT_DIR/$name.log" || code=$?
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL: $name 退出码 $code，预期 $expected" >&2
    exit 1
  fi
}

# 改变实际源数据，排除只会输出默认答案的演示。
run_demo --scenario compressed --values '3,4,-2' --json > "$REPORT_DIR/variant.json" 2> "$REPORT_DIR/variant.log"
python3 "$VERIFY" "$REPORT_DIR/variant.json" --single compressed --values '3,4,-2'
expect_exit 2 wrong-answer --scenario wrong-answer --json
python3 "$VERIFY" "$REPORT_DIR/wrong-answer.json" --single wrong-answer
expect_exit 3 expired --scenario expired --json
python3 "$VERIFY" "$REPORT_DIR/expired.json" --single expired
expect_exit 64 invalid-values --values 'not-an-integer' --json
expect_exit 64 conflicting-options --self-test --scenario preview
run_demo --help > "$REPORT_DIR/help.txt" 2> "$REPORT_DIR/help.log"

# 实际落盘、回读并确认不会覆盖已有报告。
run_demo --scenario preview --json --report "$REPORT_DIR/saved.json" > "$REPORT_DIR/saved-stdout.json" 2> "$REPORT_DIR/saved.log"
python3 "$VERIFY" "$REPORT_DIR/saved.json" --single preview
expect_exit 1 no-overwrite --scenario preview --values '3,4,-2' --report "$REPORT_DIR/saved.json"
python3 - "$REPORT_DIR" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
if json.loads((root / 'saved.json').read_text()) != json.loads((root / 'saved-stdout.json').read_text()):
    raise SystemExit('FAIL: 原有报告被改写')
report = json.loads((root / 'suite.json').read_text())
report['scenarios'][0]['actualTotal'] = 999999
(root / 'tampered.json').write_text(json.dumps(report), encoding='utf-8')
PY
# 保留 allChecksPassed=true，故意篡改答案，独立验收器仍须失败。
code=0
python3 "$VERIFY" "$REPORT_DIR/tampered.json" > "$REPORT_DIR/tamper-verification.log" 2>&1 || code=$?
if [[ "$code" != 1 ]]; then
  echo 'FAIL: 验收器没有拒绝被篡改的答案' >&2
  exit 1
fi
printf 'PASS 参数、退出码、报告回读、不覆盖和错误答案检测。\n全部自动验收通过。报告目录：%s\n' "$REPORT_DIR"
