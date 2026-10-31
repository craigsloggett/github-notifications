# github-notifications

Triage GitHub pull request notifications for the authenticated user.

## Usage

```sh
./github-notifications.sh [--dry-run]
```

For each pull request notification, the script:

1. Marks the notification as done when the pull request is closed.
2. Regenerates `README.md` with `terraform-docs` on the head branch and pushes
   the commit when Dependabot opened the pull request and the Terraform Docs
   check is the only check run on its head commit that failed, leaving the
   notification in the inbox for the next run to merge.
3. Squash-merges the pull request and marks the notification as done when
   Dependabot opened it, every check run on its head commit has succeeded, and
   GitHub reports it as clean to merge.
4. Reports every other pull request for manual review, leaving the notification
   in the inbox.

`--dry-run` reports what the script would do without pushing any commit,
merging any pull request, or marking any notification as done.

## Requirements

- `gh`, authenticated with `gh auth login` or a `GH_TOKEN` environment variable
  that has `repo` scope
- `jq`
- `git`, with push access to the Dependabot branches
- `terraform-docs`
