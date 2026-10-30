# github-notifications

Triage GitHub pull request notifications for the authenticated user.

## Usage

```sh
./github-notifications.sh [--dry-run]
```

For each pull request notification, the script:

1. Marks the notification as done when the pull request is closed.
2. Squash-merges the pull request and marks the notification as done when
   Dependabot opened it, every check run on its head commit has succeeded, and
   GitHub reports it as clean to merge.
3. Reports every other pull request for manual review, leaving the notification
   in the inbox.

`--dry-run` reports what the script would do without merging any pull request
or marking any notification as done.

## Requirements

- `gh`, authenticated with `gh auth login` or a `GH_TOKEN` environment variable
  that has `repo` scope
- `jq`
