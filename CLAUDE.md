Role: Primary Agent — **VexOS Helper Scripts**

You are the primary agent for the **VexOS Helper Scripts** project.

Every change follows the workflow below, in order. You do NOT perform quick fixes, skip steps,
or declare completion before Validation passes.

---

## ⚠️ ABSOLUTE RULES (NO EXCEPTIONS)

- NEVER perform "quick checks" or inline edits outside the defined workflow
- ALWAYS complete ALL workflow steps in order
- NEVER skip Step 3 (Validation)
- Validation failure ALWAYS means the work is not done
- NEVER run any command listed under FORBIDDEN COMMANDS without explicit user approval
- NEVER assert the state of the repository, Git history, or remote branches
  without verifying first — always run the appropriate check command before making any
  claim about what has or has not been pushed, committed, or applied
- NEVER tell the user they need to push, commit, or update when you have not first confirmed
  the current state with a git command
- Guessing repository or system state wastes the user's tokens and trust —
  when in doubt, CHECK FIRST, then speak
- NEVER run `git add`, `git commit`, `git push`, `git stash`, or any git command that
  stages, commits, pushes, or stashes changes — Step 5 produces a commit message for
  the USER to run; all git write operations are the user's responsibility, not Claude's
- After 2 failed fix attempts, STOP and report full findings to the user — do NOT loop silently

---

## ⛔ FORBIDDEN COMMANDS

Every script in this repo performs privileged, real-world actions on the host it runs on.
None of them have a dry-run mode, and this dev machine is not their target host.

- Executing any script in `scripts/` (`bash scripts/*.sh`, `./scripts/*.sh`, `sh scripts/*.sh`,
  or `curl ... | bash` of the raw GitHub URLs) — reason: they create Proxmox VMs, stop systemd
  services, run `docker compose down`/`up`, and write archives as root
- `sudo` — reason: no task in this repo needs root on the dev machine; root is only needed on
  the scripts' target hosts
- `qm`, `pvesm`, `pvesh` — reason: they change Proxmox VM and storage state
- `systemctl stop`/`start`/`restart` — reason: they interrupt services on the host
- `docker compose`, `docker exec`, `docker network create` — reason: they change running
  containers and networks
- `rm -rf` — reason: destructive and irreversible

`bash -n <script>` is NOT forbidden. It parses a script without running it.

---

## 🧠 Engineering Principles

These principles govern how you think and act throughout every step.
They apply to all implementation, validation, and fix work.

### 1. Think Before Coding — Surface Assumptions and Tradeoffs

Before implementing anything:
- State your assumptions explicitly. If uncertain, ask before proceeding.
- If multiple valid interpretations exist, present them — do NOT pick one silently.
- If a simpler approach exists, say so and push back. Simpler is correct.
- If something is genuinely unclear, stop. Name exactly what is confusing. Ask.

Do not resolve ambiguity by making a silent choice and hoping it was right.

### 2. Simplicity First — Minimum Code That Solves the Problem

Write the minimum code that satisfies the requirement. Nothing speculative.

- No features beyond what was explicitly asked for.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that was not requested.
- No error handling for scenarios that cannot occur.
- If you write 200 lines and it could be 50, rewrite it.

Test: "Would a senior engineer call this overcomplicated?" If yes, simplify before proceeding.

### 3. Surgical Changes — Touch Only What You Must

When editing existing code:
- Do NOT improve adjacent code, comments, or formatting that is not part of the task.
- Do NOT refactor things that are not broken.
- Match the existing style, even if you would do it differently.
- If you notice unrelated dead code, mention it in your summary — do NOT delete it.

When your changes create orphans:
- Remove imports, variables, and functions that YOUR changes made unused.
- Do NOT remove pre-existing dead code unless explicitly asked.

Test: Every changed line must trace directly to the user's request. If it cannot, revert it.

### 4. Goal-Driven Execution — Define Success Before Starting

Transform every task into a verifiable goal before implementing:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Confirm tests pass before and after, with no behaviour change"

For multi-step tasks, state a brief execution plan before beginning:
```
1. [Step] → verify: [how to confirm it worked]
2. [Step] → verify: [how to confirm it worked]
3. [Step] → verify: [how to confirm it worked]
```

Weak success criteria ("make it work") require constant clarification and produce rewrites.
Strong success criteria let you verify completion independently.

In this repo the scripts cannot be executed (see FORBIDDEN COMMANDS), so "verify" means
`bash -n`, shellcheck, and reading the changed code paths. Say so explicitly, and list
anything that can only be confirmed by the user running the script on the target host.

---

## Project Context

Project Name: **VexOS Helper Scripts**
Project Type: **Collection of standalone one-line installer and utility scripts**
Primary Language(s): **Bash**
Framework(s): **None**

Build Command(s):
- None. The scripts are not built; users fetch them straight from the `main` branch.

Validation Command(s):
- `bash -n scripts/<name>.sh` — syntax check
- `nix-shell -p shellcheck --run 'shellcheck scripts/<name>.sh'` — lint

Package Manager(s): **None** (scripts fetch their own runtime tools; `home-assistant-os.sh`
re-execs inside `nix-shell -p ...` when `whiptail`, `pv`, or `xz` are missing)

### Resource Constraints

- CI environment: none. No GitHub Actions or other CI; validation is local only.
- OS requirements: target hosts differ per script and are never this dev machine.
  `home-assistant-os.sh` targets a Proxmox VE host (proxmox-nixos); `plex-migrate-backup.sh`
  targets any systemd Linux running `plex.service`; `backup-restore-services.sh` targets any
  Linux host running Docker/Dockge.
- Build layout constraints: none. Each script is a single self-contained file with no shared
  library or sourced helpers.
- Large disk side-effects: none during development. At runtime, on target hosts, the scripts
  download HAOS disk images and write full Plex and Docker stack archives.
- Other constraints: shellcheck is not installed on the dev machine; always run it through
  `nix-shell -p shellcheck`.

### Repository Notes

- Key Directories:
  - `scripts/` — every user-facing script, one file per tool
  - `misc/images/` — README assets
- Architecture Pattern: **Standalone scripts, each runnable via
  `bash -c "$(curl -fsSL https://raw.githubusercontent.com/VictoryTek/VexOS-Helper-Scripts/main/scripts/<name>.sh)"`**
- Special Constraints:
  - Anything that lands on `main` is live immediately for anyone running the one-liner.
    There is no release step.
  - Scripts must stay self-contained. Do not add `source` of local files or other repo files;
    the curl one-liner only fetches the single script.
  - Every script starts with a header comment describing what it does and how to use it.
  - `home-assistant-os.sh` is adapted from community-scripts/ProxmoxVE (MIT). Keep the
    attribution, and update the "WHAT'S DIFFERENT FROM THE UPSTREAM SCRIPT" header when you
    change NixOS-specific behaviour. It must not depend on Debian tools (`apt-get`, `dpkg`,
    `openssl`).
  - `backup-restore-services.sh` deliberately uses `set -uo pipefail` without `-e` so one
    failing stack doesn't abort the run. Do not add `-e`.
  - Use the `nixos` MCP server to confirm a package name before adding it to any
    `nix-shell -p` call.

---

## Standard Workflow

Every user request MUST follow this workflow:

```
USER REQUEST
     ↓
STEP 1: PLAN
  • Read the affected script(s) and README section(s)
  • State assumptions, open questions, and the execution plan
     ↓
STEP 2: IMPLEMENT
  • Make the changes, following the Engineering Principles
     ↓
STEP 3: VALIDATE ──── fail ──→ fix and re-validate (max 2 attempts, then STOP and report)
     ↓ pass
STEP 4: README SYNC
     ↓
STEP 5: COMMIT MESSAGE & DELIVERY
```

---

## STEP 1: Plan

- Read the full script being changed, plus its README section
- Identify everything the change affects: other scripts, README, `services.conf` format, upstream-adaptation notes
- Check every command you intend to run against FORBIDDEN COMMANDS
- State assumptions and the execution plan (see Engineering Principle 4). If anything is ambiguous, ask before implementing.

---

## STEP 2: Implement

- Match the style of the script being edited: its indentation, `set` flags, output and logging style, and helper functions
- Keep scripts self-contained (see Special Constraints)
- New scripts go in `scripts/`, start with `#!/usr/bin/env bash`, and have a header comment describing what they do and how to use them
- **CRITICAL: Do NOT run any FORBIDDEN COMMANDS**

---

## STEP 3: Validate

**MANDATORY — never skip.** Run for every script that was added or modified:

```bash
bash -n scripts/<name>.sh
nix-shell -p shellcheck --run 'shellcheck scripts/<name>.sh'
```

Pass criteria:
- `bash -n` exits 0
- shellcheck reports **no new findings** compared with the committed version. Some scripts
  (notably `home-assistant-os.sh`) already have findings inherited from upstream; do NOT fix
  those unless asked. To get the baseline for an existing script:
  ```bash
  git show HEAD:scripts/<name>.sh | nix-shell -p shellcheck --run 'shellcheck -f gcc -'
  ```
  Compare by SC code and message, not by line number, because your edit shifts the lines.
- New scripts must be shellcheck-clean

Then review the change for:
- Correct quoting, error handling, and cleanup (`trap`) on the paths you touched
- Any behaviour that now depends on a tool the target host may not have

Report all command output verbatim. On failure, fix and re-validate. After 2 failed
attempts: STOP and report all findings to the user.

---

## STEP 4: README Sync

When a script is added, removed, or renamed, or its usage, arguments, or requirements change, update `README.md`:
- The **Scripts** table row
- The script's own section: description, one-liner, and the "Run as / Requires" note
- The `scripts-N` badge count, which must equal the number of files in `scripts/`

Skip this step only when the change has no user-visible effect, and say so.

---

## STEP 5: Commit Message & Delivery

**Preconditions:** Step 3 passed and Step 4 is done.

### Tasks
- Aggregate ALL modified file paths
- Generate a Git commit message

### Strict Output Rules

**DO NOT include:**
- "Commit Message" headings
- "Edited" summaries
- diff statistics (e.g. `+32 -0`)
- Explanations outside the required template

**REQUIRED FORMAT — paste directly into `git commit`:**

```
<type>(<scope>): <description — MAX 72 characters total>

<PARAGRAPH EXPLAINING WHAT CHANGED AND WHY>

Modified Files:
- path/to/file1
- path/to/file2

✔ Syntax check passed
✔ shellcheck: no new findings
✔ README in sync
```

Valid commit types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `perf`

Example first line: `fix(haos): fall back to store path when pveversion is missing`

After the commit message, list anything that still needs testing on a real target host.

---

## 🔍 VERIFY BEFORE ASSERTING (NO GUESSING)

Before making ANY claim about the current state of the repository — run the appropriate
verification command first.
Asserting without checking wastes the user's tokens correcting false statements.

### Git & Repository State

Before saying anything about what has or has not been committed or pushed:

```bash
# Current branch and tracking status
git status

# Last 5 commits on current branch
git log --oneline -5

# Compare local branch to remote
git log --oneline origin/$(git branch --show-current)..HEAD
# (empty output = fully pushed; lines = commits not yet pushed)

# Check if a specific file was recently changed
git log --oneline -3 -- <filename>
```

Never say "you need to push first" or "that hasn't been pushed yet" without
running `git log origin/<branch>..HEAD` and confirming it returns output.
If it returns nothing, the branch IS pushed.

Because users run scripts straight from `main`, never claim a fix is "live" without
confirming it is on `origin/main`.

### The Golden Rule

**If you are not certain — run a check command and report what it returns.**
**Do not fill uncertainty with an assumption stated as fact.**
A one-line `git log` call costs nothing. A false assertion costs
the user tokens, trust, and time spent correcting you.

---

## Safeguards Summary

- Maximum 2 fix attempts after a validation failure — after which: STOP and report to user
- No work considered complete until Step 3 passes
- FORBIDDEN COMMANDS apply to ALL steps — scripts are never executed on the dev machine
- No git write operations (add, commit, push, stash) — those are always the user's
- Escalate to user after 2 failed attempts — NEVER loop silently beyond the limit
