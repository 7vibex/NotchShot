

<!-- BEGIN automatic-git-publication -->
## Commit and push completed work

The user gives standing authorization to commit and push completed task changes to the project's GitHub repository. After finishing any implementation, improvement, fix, refactor, configuration, documentation, or other file-changing task, run the relevant checks, inspect the final diff, commit all changes belonging to that task with a descriptive message, and push the commit before reporting completion. Do not ask for another approval to commit or push. A later explicit user instruction to avoid committing/pushing takes precedence for that task.

Publish the task's changes, including relevant new files. Preserve unrelated pre-existing, staged, or concurrent work; never sweep it into the commit, discard it, or overwrite it. Exclude secrets, credentials, local databases, and generated build/cache artifacts. Inspect outgoing commits before pushing; do not publish unrelated unpushed commits. Use the project's configured GitHub remote and current task branch, setting an upstream when needed. If working on a detached HEAD or if publishing would include unrelated history, create a task branch from the appropriate remote base and transfer only the task changes safely. Never force-push, rewrite shared history, merge, change remotes, or bypass repository protections to satisfy this rule.

If there are no task changes, do not create an empty commit. Read-only reviewers/research agents report to the primary agent; the primary owns publication of resulting changes. If authentication, network access, repository permissions/protections, missing remote, conflicts, or failed checks prevent completion, preserve the work and report the exact blocker; do not claim a successful push. For successful publication, include the commit hash and pushed branch in the final response. Pushing may trigger configured CI/deploy workflows; this standing authorization covers that normal consequence but does not authorize separate deployment commands.
<!-- END automatic-git-publication -->
