# github-notifications

Utilities to manage GitHub notifications and pull requests automatically.

## Scripts

### github-notifications.sh

Processes pull request notifications for the authenticated user. Auto-merges
dependabot PRs (GitHub Actions and Go modules) that have passing status checks,
then marks the notifications as done.

```sh
GH_TOKEN="..." ./github-notifications.sh
```

### merge-dependabot.sh

Searches for all open dependabot pull requests owned by a given user or
organization and auto-merges (squash) those with passing status checks. Skips
PRs with merge conflicts or failing checks. Processes oldest PRs first to handle
dependency chains.

```sh
GH_TOKEN="..." ./merge-dependabot.sh <owner>
```

For example:

```sh
GH_TOKEN="..." ./merge-dependabot.sh craigsloggett
GH_TOKEN="..." ./merge-dependabot.sh craigsloggett-lab
```

## Requirements

- `curl`
- `jq`
- A GitHub personal access token with repo and pull request permissions set as `GH_TOKEN`
