# GitHub issue tracker

New specs and issues live in [gyh9457/pay-app GitHub Issues](https://github.com/gyh9457/pay-app/issues). Use `gh` with `--repo gyh9457/pay-app` for tracker operations. The [original ledger spec](../../.scratch/ledger/spec.md) and its completed numbered tickets are historical records.

## Tracker operations

- Publish specs and tasks with `gh issue create --repo gyh9457/pay-app --title "..." --body-file <file>`.
- Read a ticket with `gh issue view <number> --repo gyh9457/pay-app --json number,title,state,stateReason,body,labels,comments,blockedBy`.
- Find active work with `gh issue list --repo gyh9457/pay-app --state open`, using label filters as needed. See [triage labels](triage-labels.md) for the project vocabulary.
- Link a task to its spec with `gh issue edit <spec> --repo gyh9457/pay-app --add-sub-issue <task>`.
- Record prerequisites with `gh issue edit <task> --repo gyh9457/pay-app --add-blocked-by <prerequisite>`. Check `blockedBy` before starting. A prerequisite is satisfied once it is closed as completed.
- Update labels with `gh issue edit <number> --repo gyh9457/pay-app --add-label <label> --remove-label <previous-label>`. Add progress and evidence with `gh issue comment <number> --repo gyh9457/pay-app --body-file <file>`.
- For completed work that requires no repository changes, record the outcome before closing with `gh issue close <number> --repo gyh9457/pay-app --reason completed`.

## Single-agent pull request workflow

- Prepare each task with its scope, dependencies, and acceptance criteria. Work on the lowest-numbered eligible task within the current scope. Mark it `in-progress`, validate the name under [Task branch names](#task-branch-names), and create the task branch from the latest default branch. Resume existing work from its branch, PR, and verification notes.
- The same agent implements, tests, and reviews the changes against the acceptance criteria. Fix any failed criteria and rerun the relevant checks.
- If a user decision about scope or behavior is required, apply `needs-info` and record the question and evidence. Update the acceptance criteria and resume once the question is resolved.
- Commit and push the task branch. Open a PR targeting the default branch with `gh pr create --repo gyh9457/pay-app --base <default-branch> --body-file <file>`. Include `Closes #<issue-number>` for the tasks the PR fully delivers. Record the change summary, verification commands and results, and any deferred checks in the PR. Mark the issue `ready-for-review` when the PR is ready for review and merge checks.
- Keep the issue open until the PR is merged. Follow the repository's required checks and approvals before merging. Use the [commit message convention](../../AGENTS.md#git-提交信息) for the final commit title. After the PR merges into the default branch, verify that GitHub closed the linked issue as completed. If it remains open, record the merged PR and close the issue as completed.
- When the last task for a spec is merged and complete, run the final integration checks. Record the delivery results and relevant PRs on the spec issue, and close the spec once its acceptance criteria pass.
- The repository is public. Use example amounts and remove private device details from issue bodies, comments, and test logs before posting.

## Task branch names

Name new task branches `<type>/<issue-number>-<short-description>`, such as `feat/1-expense-note`. Use `feat` for features, `fix` for bug fixes, `docs` for documentation, and `chore` for maintenance. Use the actual GitHub Issue number and a short description with lowercase ASCII letters or digits separated by hyphens.

Set `issue_number` to the task's GitHub Issue number and `branch_name` to the proposed name. Run this check before creating the branch and again before its first push. If the check fails, correct the name before proceeding.

```sh
printf '%s\n' "$branch_name" |
  LC_ALL=C grep -Eq "^(feat|fix|docs|chore)/${issue_number}-[a-z0-9]+(-[a-z0-9]+)*$" &&
  git check-ref-format --branch "$branch_name"
```

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

`/wayfinder` stores its map in an issue labelled `wayfinder:map` and links each child ticket as a sub-issue labelled `wayfinder:<type>`. Create missing Wayfinding labels when using this workflow. Use GitHub dependencies for blockers. Pick the first open, unblocked, unassigned child in map order, and claim it with `gh issue edit <number> --repo gyh9457/pay-app --add-assignee @me`. Record the answer in a comment, close the child as completed, and add a summary and link to the map's Decisions-so-far.
