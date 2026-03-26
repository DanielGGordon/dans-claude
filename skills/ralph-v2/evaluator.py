"""Evaluator output parsing for Ralph v2."""

import re

from models import EvalResult, EvalCriterionResult


_OVERALL_RE = re.compile(
    r"\*\*Overall\*\*\s*:\s*(PASS|FAIL)",
    re.IGNORECASE,
)
_CRITERION_HEADING_RE = re.compile(
    r"^###\s+Criterion\s+\d+\s*:\s*(.+)$",
    re.IGNORECASE,
)
_RESULT_RE = re.compile(
    r"\*\*Result\*\*\s*:\s*(PASS|FAIL)",
    re.IGNORECASE,
)
_EVIDENCE_RE = re.compile(r"\*\*Evidence\*\*\s*:\s*(.+)$", re.IGNORECASE)
_ISSUE_RE = re.compile(r"\*\*Issue\*\*\s*:\s*(.+)$", re.IGNORECASE)
_SUGGESTION_RE = re.compile(r"\*\*Suggestion\*\*\s*:\s*(.+)$", re.IGNORECASE)


def parse_eval_output(raw_output: str) -> EvalResult:
    """Parse structured evaluator output into an EvalResult.

    The evaluator is instructed to produce output in a specific format:

        ## Phase N Evaluation
        **Overall**: PASS / FAIL (X of Y criteria met)
        ### Criterion 1: [description]
        **Result**: PASS
        **Evidence**: [what was tested]
        ### Criterion 2: [description]
        **Result**: FAIL
        **Issue**: [problem]
        **Suggestion**: [fix direction]

    If parsing fails, falls back to heuristic PASS/FAIL detection.
    """
    lines = raw_output.splitlines()
    criteria_results: list[EvalCriterionResult] = []

    # Parse overall result
    overall_passed = None
    for line in lines:
        m = _OVERALL_RE.search(line)
        if m:
            overall_passed = m.group(1).upper() == "PASS"
            break

    # Parse per-criterion results
    current_criterion = ""
    current_passed = None
    current_detail_parts: list[str] = []

    def _flush():
        if current_criterion and current_passed is not None:
            criteria_results.append(EvalCriterionResult(
                criterion=current_criterion,
                passed=current_passed,
                detail="\n".join(current_detail_parts).strip(),
            ))

    for line in lines:
        stripped = line.strip()

        # New criterion heading
        m = _CRITERION_HEADING_RE.match(stripped)
        if m:
            _flush()
            current_criterion = m.group(1).strip()
            current_passed = None
            current_detail_parts = []
            continue

        # Result line
        m = _RESULT_RE.search(stripped)
        if m and current_criterion:
            current_passed = m.group(1).upper() == "PASS"
            continue

        # Detail lines
        if current_criterion and current_passed is not None:
            for pattern in (_EVIDENCE_RE, _ISSUE_RE, _SUGGESTION_RE):
                dm = pattern.search(stripped)
                if dm:
                    current_detail_parts.append(dm.group(1).strip())
                    break

    _flush()

    # Determine overall pass/fail
    if overall_passed is None:
        # Fallback: all criteria must pass
        if criteria_results:
            overall_passed = all(cr.passed for cr in criteria_results)
        else:
            # No structured output -- use heuristic
            overall_passed = _heuristic_pass(raw_output)

    # Build summary
    if criteria_results:
        passed_count = sum(1 for cr in criteria_results if cr.passed)
        total_count = len(criteria_results)
        summary = f"{passed_count}/{total_count} criteria passed"
    else:
        summary = "PASS" if overall_passed else "FAIL"

    return EvalResult(
        passed=overall_passed,
        criteria_results=criteria_results,
        summary=summary,
        raw_output=raw_output,
    )


def _heuristic_pass(text: str) -> bool:
    """Fallback: check if the evaluator output looks like a pass."""
    text_lower = text.lower()
    fail_signals = ["fail", "broken", "error", "missing", "not working", "issue"]
    pass_signals = ["pass", "all criteria met", "lgtm", "looks good"]

    fail_count = sum(1 for s in fail_signals if s in text_lower)
    pass_count = sum(1 for s in pass_signals if s in text_lower)

    return pass_count > fail_count


def format_eval_summary(eval_result: EvalResult) -> str:
    """Format a concise summary of evaluation results for display."""
    parts = [f"Eval: {eval_result.summary}"]
    for cr in eval_result.criteria_results:
        status = "PASS" if cr.passed else "FAIL"
        parts.append(f"  [{status}] {cr.criterion}")
        if cr.detail and not cr.passed:
            # Show first line of detail for failures
            first_line = cr.detail.splitlines()[0]
            parts.append(f"         {first_line}")
    return "\n".join(parts)
