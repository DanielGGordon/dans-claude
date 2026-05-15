"""Interactive launcher -- fzf/menu plan and model selection."""

import shutil
import subprocess
import sys
from pathlib import Path

from models import Config, MODEL_PRESETS


def _has_fzf() -> bool:
    return shutil.which("fzf") is not None


def _fzf_select(choices: list[str], prompt: str, preview: str = "") -> str:
    cmd = ["fzf", "--prompt", prompt, "--height", "~20", "--reverse"]
    if preview:
        cmd += ["--preview", preview]
    try:
        proc = subprocess.run(
            cmd, input="\n".join(choices),
            capture_output=True, text=True, timeout=120,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _menu_select(choices: list[str], prompt: str) -> str:
    print(f"\n  {prompt}")
    for i, c in enumerate(choices, 1):
        marker = " (default)" if i == 1 else ""
        print(f"    {i}. {c}{marker}")
    while True:
        try:
            raw = input(f"  Choice [1-{len(choices)}, default=1]: ").strip()
        except (EOFError, KeyboardInterrupt):
            return choices[0]
        if not raw:
            return choices[0]
        try:
            idx = int(raw)
            if 1 <= idx <= len(choices):
                return choices[idx - 1]
        except ValueError:
            pass
        print(f"    Enter 1\u2013{len(choices)}")


def _pick(choices: list[str], prompt: str, preview: str = "",
          default: str = "") -> str:
    if not choices:
        return ""
    if default and default in choices:
        choices = [default] + [c for c in choices if c != default]
    if _has_fzf():
        result = _fzf_select(choices, prompt, preview)
        if result:
            return result
        print("Selection cancelled.", file=sys.stderr)
        sys.exit(1)
    return _menu_select(choices, prompt)


def _collect_plan_files() -> list[str]:
    """Gather .md plan files from cwd, ./plans/, and ~/.claude/plans/."""
    seen: set[str] = set()
    plans: list[str] = []

    def _add(p: Path) -> None:
        resolved = str(p.resolve())
        if resolved not in seen:
            seen.add(resolved)
            plans.append(str(p))

    for name in ("plan.md", "PLAN.md"):
        p = Path(name)
        if p.is_file():
            _add(p)
    for d in (Path("plans"), Path.home() / ".claude" / "plans"):
        if d.is_dir():
            for p in sorted(d.glob("*.md")):
                _add(p)
    return plans


def interactive_config(config: Config, explicit: dict[str, bool]) -> Config:
    """Prompt for any config values not already set via CLI flags or env vars."""
    # -- Plan selector --
    if not explicit["plan_path"]:
        plans = _collect_plan_files()
        if not plans:
            print("Error: no plan files found (./plans/, ~/.claude/plans/, "
                  "or ./plan.md)", file=sys.stderr)
            sys.exit(1)
        if len(plans) == 1:
            config.plan_path = str(Path(plans[0]).resolve())
            print(f"  Auto-selected plan: {plans[0]}")
        else:
            selected = _pick(plans, "Plan: ", preview="head -20 {}")
            config.plan_path = str(Path(selected).resolve())

    # -- Model selector --
    if not explicit["model"]:
        presets = list(MODEL_PRESETS.keys())
        selected = _pick(presets, "Model: ", default="opus-xhigh")
        if selected in MODEL_PRESETS:
            config.model, config.effort = MODEL_PRESETS[selected]
        else:
            config.model = selected

    # -- Evaluator toggle --
    if not explicit["eval"]:
        selected = _pick(["yes", "no"], "Run evaluator after each phase? ",
                         default="yes")
        config.skip_eval = (selected != "yes")

    return config
