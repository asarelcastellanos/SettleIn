# Repository settings

This page lists the GitHub settings that protect the repository. Each section gives the reason for the setting, the command that applies it, and the command that reads it back. The repository owner runs the commands with their own `gh` login. Nothing in the repository stores a token.

The commands write `{owner}` and `{repo}` literally. `gh api` fills both in from the current clone, so run the commands from inside a clone of this repository.

Apply the branch protection last. It blocks direct pushes to `main`, and it applies to administrators too.

## Branch protection on main

**Reason.** Nobody can change `main` without a pull request. Force pushes and branch deletion are blocked, so history stays intact. Linear history keeps `main` a straight line of squashed commits. Enforcing the rules for administrators means the owner has the same single path as everyone else.

The rule requires a pull request with 0 approving reviews, because a solo owner cannot approve their own pull request. Raise `required_approving_review_count` when a second maintainer joins. The rule sets no required status checks, because none exist until the weekly workflow in issue 13.

Apply:

```sh
gh api -X PUT repos/{owner}/{repo}/branches/main/protection --input - <<'EOF'
{"required_status_checks":null,"enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null,"required_linear_history":true,"allow_force_pushes":false,"allow_deletions":false}
EOF
```

Read back:

```sh
gh api repos/{owner}/{repo}/branches/main/protection --jq '{pr: (.required_pull_request_reviews != null), force: .allow_force_pushes.enabled, delete: .allow_deletions.enabled, linear: .required_linear_history.enabled, admins: .enforce_admins.enabled}'
```

Expected output is `pr` true, `force` false, `delete` false, `linear` true, and `admins` true. Before the rule exists, the command fails with HTTP 404 and the message "Branch not protected".

## Dependabot alerts

**Reason.** GitHub opens an alert when a dependency in the repository has a known vulnerability. Alerts must be on before security updates can work.

Apply:

```sh
gh api -X PUT repos/{owner}/{repo}/vulnerability-alerts
```

Read back:

```sh
gh api repos/{owner}/{repo}/vulnerability-alerts --include | head -1
```

The first line shows `204` when alerts are on. It shows `404` when they are off.

## Dependabot security updates

**Reason.** Dependabot opens a pull request that upgrades a vulnerable dependency to a patched version. The version updates in `.github/dependabot.yml` are separate. They run weekly for `/app/SettleInCore`.

Apply:

```sh
gh api -X PUT repos/{owner}/{repo}/automated-security-fixes
```

Read back:

```sh
gh api repos/{owner}/{repo}/automated-security-fixes --jq .enabled
```

The command prints `true` when security updates are on.

## Secret scanning and push protection

**Reason.** Secret scanning reports credentials that were committed to the repository. Push protection rejects a push that contains a recognized credential before it reaches GitHub.

Apply:

```sh
gh api -X PATCH repos/{owner}/{repo} --input - <<'EOF'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
EOF
```

Read back:

```sh
gh api repos/{owner}/{repo} --jq '.security_and_analysis | {secret_scanning: .secret_scanning.status, push_protection: .secret_scanning_push_protection.status}'
```

The command prints `enabled` for both fields.

## Private vulnerability reporting

**Reason.** A researcher who finds a vulnerability can report it to the maintainers privately through the Security tab, without opening a public issue.

Apply:

```sh
gh api -X PUT repos/{owner}/{repo}/private-vulnerability-reporting
```

Read back:

```sh
gh api repos/{owner}/{repo}/private-vulnerability-reporting --jq .enabled
```

The command prints `true` when reporting is on.

## Merge settings

**Reason.** Squash merge is the only allowed method, so every pull request becomes one commit on `main`. The squash commit takes the pull request title as its subject and the pull request body as its message. GitHub deletes the head branch after the merge, so merged branches do not pile up.

Apply:

```sh
gh api -X PATCH repos/{owner}/{repo} --input - <<'EOF'
{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY","delete_branch_on_merge":true}
EOF
```

Read back:

```sh
gh api repos/{owner}/{repo} --jq '{squash: .allow_squash_merge, merge: .allow_merge_commit, rebase: .allow_rebase_merge, delete_branch: .delete_branch_on_merge, title: .squash_merge_commit_title, message: .squash_merge_commit_message}'
```

The command prints `squash` true, `merge` false, `rebase` false, `delete_branch` true, `title` "PR_TITLE", and `message` "PR_BODY".
