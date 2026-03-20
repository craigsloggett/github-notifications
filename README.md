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

### fix-terraform-docs.sh

Searches for open dependabot Terraform pull requests with a failing terraform-docs
check. For each one, clones the branch to a temporary directory, regenerates the
documentation, commits, and pushes. Run before `merge-dependabot.sh` so checks
pass by the time the merge script runs.

```sh
GH_TOKEN="..." ./fix-terraform-docs.sh <owner>
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
- `git`
- `terraform-docs` (for `fix-terraform-docs.sh`)
- A GitHub personal access token with repo and pull request permissions set as `GH_TOKEN`
