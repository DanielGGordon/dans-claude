#!/usr/bin/env bash
#
# Stop hook: review plan before Claude stops after writing one.
#
# Detection: finds the most recently modified plan file (within 120s) from:
# 1. ~/.claude/plans/*.md  (where Claude Code writes plans in plan mode)
# 2. plan.md / PLAN.md in the working directory
#
# To block the stop and send Claude back to revise, exit 2 with
# feedback on stderr. To allow the stop, exit 0.
#
# Checks stop_hook_active to prevent infinite review loops.

set -e

INPUT=$(cat)

# Prevent infinite loops: if we already blocked once, let Claude stop
STOP_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null)
if [ "$STOP_ACTIVE" = "True" ] || [ "$STOP_ACTIVE" = "true" ]; then
  exit 0
fi

# Extract CWD from hook data
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd', ''))" 2>/dev/null)

# Find the most recently modified plan file (must be within 120s)
PLAN_FILE=""
NOW=$(date +%s)
BEST_AGE=999999

# Check ~/.claude/plans/*.md
for candidate in "$HOME"/.claude/plans/*.md; do
  [ -f "$candidate" ] || continue
  mod_time=$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null)
  age=$(( NOW - mod_time ))
  if [ "$age" -le 120 ] && [ "$age" -lt "$BEST_AGE" ]; then
    BEST_AGE="$age"
    PLAN_FILE="$candidate"
  fi
done

# Check plan.md / PLAN.md in CWD
if [ -n "$CWD" ]; then
  for name in plan.md PLAN.md; do
    candidate="$CWD/$name"
    [ -f "$candidate" ] || continue
    mod_time=$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null)
    age=$(( NOW - mod_time ))
    if [ "$age" -le 120 ] && [ "$age" -lt "$BEST_AGE" ]; then
      BEST_AGE="$age"
      PLAN_FILE="$candidate"
    fi
  done
fi

# No recently modified plan file — allow stop
if [ -z "$PLAN_FILE" ]; then
  exit 0
fi

# Resolve requirements file
REQUIREMENTS="$HOME/.claude/plan-requirements.md"
if [ ! -f "$REQUIREMENTS" ]; then
  exit 0
fi

# Run the plan review
FEEDBACK=$(python3 - "$PLAN_FILE" "$REQUIREMENTS" << 'PYEOF'
import sys, re

plan_path = sys.argv[1]
req_path = sys.argv[2]

with open(plan_path) as f:
    plan = f.read()

if not plan.strip():
    sys.exit(0)

plan_lower = plan.lower()

issues = []

# 1. Testing Strategy — needs named frameworks and test types
test_frameworks = [
    "jest", "pytest", "playwright", "cypress", "vitest", "mocha", "junit",
    "rspec", "minitest", "cargo test", "go test", "tap", "ava", "jasmine",
    "selenium", "puppeteer", "testing-library", "supertest", "httptest",
    "unittest", "nose", "testify", "xunit", "nunit", "catch2", "gtest",
]
has_framework = any(fw in plan_lower for fw in test_frameworks)

test_types = ["unit test", "integration test", "end-to-end", "e2e", "smoke test", "contract test"]
has_test_type = any(tt in plan_lower for tt in test_types)

if not has_framework:
    issues.append("**Testing Strategy**: No specific test framework named (e.g. Jest, Pytest, Playwright). 'We will write tests' is not sufficient.")
if not has_test_type:
    issues.append("**Testing Strategy**: No test types specified (unit, integration, e2e, etc.).")

# 2. System Tools / External Dependencies
dep_keywords = ["docker", "database", "api key", "credential", "cli tool", "browser automation",
                "aws", "gcp", "azure", "vercel", "mock server", "redis", "postgres", "mysql",
                "mongo", "infrastructure", "pip install", "npm install", "brew install",
                "apt install", "dependencies", "requirements.txt", "package.json"]
has_deps_section = any(kw in plan_lower for kw in dep_keywords)
dep_headers = re.findall(r'#+\s*.*(dependenc|tool|prerequisite|requirement|setup|install).*', plan_lower)
if not has_deps_section and not dep_headers:
    issues.append("**System Tools & Dependencies**: No section enumerating external tools/services needed for testing.")

# 3. Human-in-the-Loop — must be explicit (either "no human steps" or a labeled section)
human_keywords = ["human", "manual", "human-in-the-loop", "no manual", "no human",
                  "fully automated", "initial setup", "one-time setup"]
has_human_policy = any(kw in plan_lower for kw in human_keywords)
if not has_human_policy:
    issues.append("**Human-in-the-Loop**: Plan must explicitly state whether human steps are required. If none, say so.")

# 4. Agent-Loop Compatible Task Lists — needs structured tasks with completion criteria
has_checkbox = bool(re.search(r'- \[[ x]\]', plan))
has_numbered_tasks = bool(re.search(r'^\d+\.\d*\s', plan, re.MULTILINE))
has_task_table = bool(re.search(r'\|.*task.*\|', plan_lower))
has_completion_criterion = any(kw in plan_lower for kw in ["criterion", "criteria", "done when", "complete when", "verification", "expected outcome"])

if not (has_checkbox or has_numbered_tasks or has_task_table):
    issues.append("**Task List**: No structured task list found (need checkbox items, numbered tasks, or a task table).")
elif not has_completion_criterion:
    issues.append("**Task List**: Tasks lack clear completion criteria (how do you know each task is done?).")

# 5. Parallelism markers
parallel_keywords = ["parallel", "concurrent", "can run in parallel", "parallelizable",
                     "no dependencies", "independent"]
has_parallel = any(kw in plan_lower for kw in parallel_keywords)
if not has_parallel:
    issues.append("**Parallelism**: No parallel/sequential markers on tasks. Mark which tasks can run concurrently.")

# 6. Task List Completeness — needs setup, development, testing, deployment phases
phases = {
    "setup": ["setup", "environment", "install", "provision", "bootstrap", "initialize"],
    "development": ["implement", "develop", "build", "create", "code", "feature"],
    "testing": ["test", "verify", "validate", "assert", "spec"],
    "deployment": ["deploy", "release", "build", "ship", "publish", "ci/cd", "pipeline"],
}
missing_phases = []
for phase, keywords in phases.items():
    if not any(kw in plan_lower for kw in keywords):
        missing_phases.append(phase)

if missing_phases:
    issues.append(f"**Task Completeness**: Plan is missing tasks for: {', '.join(missing_phases)}. Must cover setup → development → testing → deployment.")

if issues:
    print("FAIL")
    print("\n".join(issues))
else:
    print("PASS")

PYEOF
)

# Parse result
RESULT=$(echo "$FEEDBACK" | head -1)

if [ "$RESULT" = "FAIL" ]; then
  DETAILS=$(echo "$FEEDBACK" | tail -n +2)
  echo "Plan review failed. Revise the plan to address these issues before exiting plan mode:" >&2
  echo "" >&2
  echo "$DETAILS" >&2
  if [ -n "$PLAN_FILE" ]; then
    echo "" >&2
    echo "Plan file: $PLAN_FILE" >&2
  fi
  exit 2
fi

# Plan passed or review couldn't run — allow stop
exit 0
