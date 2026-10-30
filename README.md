# github-notifications

Triage GitHub pull request notifications for the authenticated user.

## Usage

```sh
./github-notifications.sh
```

The script marks the notifications for closed pull requests as done, then
reports on each open pull request.

## Requirements

- `gh`, authenticated with `gh auth login` or a `GH_TOKEN` environment variable
  that has `repo` (or `notifications`) scope
- `jq`
