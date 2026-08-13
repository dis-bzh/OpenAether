---
name: public-repo-safety
description: What may and may not be committed to OpenAether-infra and OpenAether-apps, which are public — real environment data, derived files, and the .claude directory. Use before committing anything containing an address, an id, a name from a real account, or any change under .claude.
---

# Both repositories are public

No IP, account id, project id, bucket name, image id, hostname or key material —
not in code, not in a comment, **not in a commit message**. The rule is not "no
secrets"; it is no data belonging to a real environment.

The pattern already in place: `envs/*.tfvars` is real and gitignored, only
`*.tfvars.example` with placeholders is public.

## The two ways this has actually leaked

**Derived files.** `*.tfvars` does not match `management-ovh.tfvars.bak`. Copying
an env file before editing it — what anyone does — left real IPs and account ids
untracked but visible, one `git add -A` from the incident below. `*.tfvars.*`
covers the derived forms now. Before adding a gitignore rule, ask what the *next*
person's filename will look like.

**Commit messages.** The 2026-07-31 purge needed `git filter-repo` with
`--replace-text` **and** `--replace-message`. The first alone does not touch
commit messages, and the IPs were in both.

## Before you commit

    git diff --cached | grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}'

and read the hits. `gitleaks` runs in `task security` and in pre-commit, but it
looks for credentials, not for your cluster's addresses.

## The `.claude` directory

`CLAUDE.md`, `.claude/skills/**` and `.claude/hooks/**` are instructions an agent
will follow, and the hook runs by itself. So:

- **A pull request touching them is a code-execution pull request.** Read that
  diff before running any agent on the branch. The rule against
  `pull_request_target` in a credentialed workflow has the same shape: never give
  a stranger's branch your credentials.
- `.claude/settings.json` is publishable **while it declares no
  `permissions.allow`**. An allowlist is not documentation; it is an execution
  grant, and a PR editing `Taskfile.yml` or `scripts/**` then runs unprompted on a
  maintainer's machine.
- Everything the hook downloads is pinned and checksum-verified, like every other
  download here. A remote script fetched from a moving branch and piped to bash is
  the thing this rule exists to stop.
- `settings.local.json`, session transcripts and MCP configs stay out of git.
