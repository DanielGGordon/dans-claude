#!/usr/bin/env bash
#
# Stop hook: review plan before Claude stops after writing one.
#
# Two detection paths:
# 1. permission_mode == "plan" → reads plan from last_assistant_message
# 2. Fallback: plan.md/PLAN.md modified in CWD within 120s → reads from file
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

# Extract fields from hook data
eval "$(echo "$INPUT" | python3 -c "
import sys, json, shlex
d = json.load(sys.stdin)
print(f'PERM_MODE={shlex.quote(str(d.get(\"permission_mode\", \"\")))}')
print(f'CWD={shlex.quote(str(d.get(\"cwd\", \"\")))}')
" 2>/dev/null)"

# Determine plan source: plan mode message or file on disk
PLAN_SOURCE=""  # "message" or "file"
PLAN_FILE=""

if [ "$PERM_MODE" = "plan" ]; then
  # In plan mode — the plan is in last_assistant_message
  PLAN_SOURCE="message"
else
  # Not in plan mode — check for recently modified plan file
  if [ -n "$CWD" ]; then
    for name in plan.md PLAN.md; do
      candidate="$CWD/$name"
      if [ -f "$candidate" ]; then
        mod_time=$(stat -c %Y "$candidate" 2>/dev/null || stat -f %m "$candidate" 2>/dev/null)
        now=$(date +%s)
        age=$(( now - mod_time ))
        if [ "$age" -le 120 ]; then
          PLAN_SOURCE="file"
          PLAN_FILE="$candidate"
          break
        fi
      fi
    done
  fi
fi

# No plan detected — allow stop
if [ -z "$PLAN_SOURCE" ]; then
  exit 0
fi

# Resolve requirements file
REQUIREMENTS="$HOME/.claude/plan-requirements.md"
if [ ! -f "$REQUIREMENTS" ]; then
  exit 0
fi

# Run the plan review
FEEDBACK=$(echo "$INPUT" | python3 - "$PLAN_SOURCE" "$PLAN_FILE" "$REQUIREMENTS" << 'PYEOF'
import sys, re, json

def read_file(path):
    with open(path) as f:
        return f.read()

plan_source = sys.argv[1]  # "message" or "file"
plan_file = sys.argv[2]    # path (only used if source == "file")
req_path = sys.argv[3]

# Get plan text
if plan_source == "message":
    hook_data = json.load(sys.stdin)
    plan = hook_data.get("last_assistant_message", "")
elif plan_source == "file":
    plan = read_file(plan_file)
else:
    sys.exit(0)

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
  if [ "$PLAN_SOURCE" = "message" ]; then
    echo "Plan review failed. Revise the plan to address these issues before exiting plan mode:" >&2
  else
    echo "Plan review failed. Revise the plan to address these issues before proceeding:" >&2
  fi
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
