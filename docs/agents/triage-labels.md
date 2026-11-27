# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

GitHub delivery labels also include `in-progress` (implementation and verification underway) and `ready-for-review` (the PR is ready for review and merge checks). Implementation issues reach **Closed as completed** after their PR merges. `done` remains the historical Markdown status. A recoverable interruption leaves an `in-progress` issue eligible for resumption after the previous execution is confirmed stopped. If self-review finds a failed criterion, the agent records it, fixes the issue, and reruns the relevant checks.
