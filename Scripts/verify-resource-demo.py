#!/usr/bin/env python3
"""独立核对离线 Demo 报告，不调用模型，也不只相信报告的 PASS 标记。"""
import argparse
import json
from pathlib import Path
import sys

SCENARIOS = {
    "preview": ("accepted", 3, 1, 1),
    "compressed": ("accepted", 5, 1, 1),
    "expired": ("blocked", 2, 1, 0),
    "denied": ("blocked", 2, 1, 0),
    "wrong-answer": ("rejected", 3, 1, 1),
    "lost-reference": ("blocked", 4, 0, 0),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate(report, names, values):
    require(report.get("schemaVersion") == 1, "未知报告版本")
    require(report.get("modelMode") == "offline-deterministic" and report.get("liveProvider") is False,
            "报告不能冒充真实模型测评")
    rows = report["scenarios"]
    require(len(rows) == len(names), "场景数量不符")
    require({r["scenario"] for r in rows} == set(names), "场景缺失、重复或多余")
    expected_total = sum(values)
    outcomes = {"accepted": 0, "rejected": 0, "blocked": 0}
    for row in rows:
        name = row["scenario"]
        outcome, calls, attempts, successes = SCENARIOS[name]
        prefix = name + ": "
        require(row["inputValues"] == values and row["expectedTotal"] == expected_total, prefix + "输入或预期值不符")
        require(row["taskOutcome"] == outcome and row["expectedOutcome"] == outcome, prefix + "任务状态不符")
        require(row["businessInferenceCalls"] == calls, prefix + "推理次数不符")
        reads = row["reads"]
        require(reads["lookups"] == 1 and reads["previewBytes"] == 64, prefix + "未使用一次有界预览")
        require(reads["readAttempts"] == attempts and reads["successfulReads"] == successes, prefix + "回读次数不符")
        require(reads["returnedBytes"] == 512 * successes, prefix + "回读字节数不符")
        numeric = [row[key] for key in ("sourceUTF8Bytes", "businessInputBytes", "summaryInputBytes",
                   "compactionCount", "summaryInferenceCalls", "removedToolExchanges", "estimatedTokenReduction")]
        require(all(type(v) is int and v >= 0 for v in numeric), prefix + "非法计数")
        require(row["sourceUTF8Bytes"] > 1_048_576, prefix + "大资源场景未建立")
        require(row["businessInputBytes"] + row["summaryInputBytes"] < row["sourceUTF8Bytes"] // 10,
                prefix + "大正文被重复携带")
        compressed = name in ("compressed", "lost-reference")
        if compressed:
            require(row["compactionCount"] > 0 and 0 < row["summaryInferenceCalls"] <= 2,
                    prefix + "压缩或摘要没有实际发生")
            require(row["removedToolExchanges"] >= 2 and row["estimatedTokenReduction"] > 0,
                    prefix + "旧上下文未减少")
            require(row["originalCardRemoved"] is True, prefix + "原预览仍在，未验证摘要回读")
        else:
            require(row["compactionCount"] == 0 and row["summaryInferenceCalls"] == 0,
                    prefix + "未启用压缩却执行摘要")
        require(row["referenceRecoveredFromSummary"] is (name == "compressed"), prefix + "引用恢复事实不符")
        if outcome in ("accepted", "rejected"):
            require(row["modelRunSucceeded"] is True and row.get("sdkError") is None, prefix + "Agent 未完成")
            require(row.get("actualValues") == values, prefix + "实际读出的数据错误")
            target = expected_total + (1 if name == "wrong-answer" else 0)
            require(row.get("actualTotal") == target, prefix + "最终答案与独立预期不符")
        else:
            require(row["modelRunSucceeded"] is False, prefix + "失败场景假报运行成功")
            require(row.get("actualValues") is None and row.get("actualTotal") is None, prefix + "失败后伪造答案")
            error = "inferenceFailed" if name == "lost-reference" else "toolExecutionFailed"
            require(row.get("sdkError") == error, prefix + "异常原因与注入点不符")
        require(len(row["checks"]) >= 9 and all(c.get("passed") is True for c in row["checks"]), prefix + "内部行为检查未通过")
        require(bool(row["trace"]), prefix + "缺少执行步骤")
        outcomes[outcome] += 1
        print(f"PASS {name}: task={outcome}, total={row.get('actualTotal')}, reads={successes}/{attempts}, summary={row['summaryInferenceCalls']}")
    require(report.get("allChecksPassed") is True, "批量行为验收未通过")
    print(f"验证通过：{len(rows)} 场景；交付 {outcomes['accepted']}，正确拒绝 {outcomes['rejected']}，正确阻止 {outcomes['blocked']}。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--single", choices=SCENARIOS)
    parser.add_argument("--values", default="17,23,60")
    args = parser.parse_args()
    try:
        values = [int(v.strip()) for v in args.values.split(",")]
        require(1 <= len(values) <= 32 and all(-100_000 <= v <= 100_000 for v in values), "非法预期输入")
        report = json.loads(args.report.read_text(encoding="utf-8"))
        validate(report, [args.single] if args.single else list(SCENARIOS), values)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
