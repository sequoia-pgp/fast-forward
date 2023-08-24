# Fast Forward Pull Requests

This repository contains a GitHub action that merges a pull request by
fast forwarding the target branch.  The action is triggered when an
authorized user adds a comment containing `/fast-forward` to the pull
request.

As the following screenshot shows, GitHub's web UX allows the user to
select from several different merge strategies:

![Screenshot of GitHub's Merge pull request options: "Create a merge
  commit", "Squash and merge", and "Rebase and
  merge"](assets/merge-pull-request.jpg)

Unfortunately, none of the strategies fast forward the target branch
even when fast forwarding is possible.  In particular, the `Rebase and
merge` strategy unconditionally rewrites the commits by changing each
commit's `committer` field.  This causes the commits to have a
different hash, and destroys any signatures.

With a bit of work, it is possible to prevent GitHub from modifying
the commits.  Specifically, it is possible to push changes from a pull
request directly to the target branch after any checks have passed.
Consider:

```shell
$ # We can't directly push to main, because it is protected.
$ git push origin
...
remote: error: GH006: Protected branch update failed for refs/heads/main.
...
$ # We can create a PR, wait for the CI checks to pass, then push directly to main.
$ git push origin HEAD:workwork
$ git push origin
```

This approach isn't very convenient.

The `fast-forward` action improves the situation a bit by making it
possible to fast forward directly from the web UX by posting a comment
on the pull request.

## Checking if Fast Forwarding is Possible

By default `fast-forward` checks if a pull request can be merged.  It
adds a comment on the pull request indicating if this is the case, or
if the pull request needs to be rebased.  To run this check whenever a
pull request is opened or updated, add
`.github/workflows/pull_request.yml` to your repository with the
following contents:

```yaml
name: pull-request
on:
  pull_request:
    types: [opened, reopened, synchronize]
jobs:
  check-fast-forward:
    runs-on: ubuntu-latest

    permissions:
      contents: read
      # We appear to need write permission for both pull-requests and
      # issues in order to post a comment to a pull request.
      pull-requests: write
      issues: write

    steps:
      - name: Checking if fast forwarding is possible
        uses: sequoia-pgp/fast-forward@main
```

## Fast Forwarding a Pull Request

To actually fast-forward a branch, add
`.github/workflows/fast-forward.yml` to your repository with the
following contents:

```yaml
name: fast-forward
on:
  issue_comment:
    types: [created, edited]
jobs:
  fast-forward:
    # Only run if the comment contains the /fast-forward command.
    if: ${{ contains(github.event.comment.body, '/fast-forward')
            && github.event.issue.pull_request }}
    runs-on: ubuntu-latest

    permissions:
      contents: write
      pull-requests: write
      issues: write

    steps:
      - name: Fast forwarding
        uses: sequoia-pgp/fast-forward@main
        with:
            merge: true
```

This workflow is only run when a comment that includes `/fast-forward`
is added to the pull request.  The workflow is careful to check that
the user who triggered the workflow is actually authorized to push to
the repository.

## Disabling Comments

If you prefer to disable comments, you can set the `comment` input
variable to `false`.  The `comment` is also written to the `comment`
output variable so it is possible to use it in a successive step.  The
format is a JSON document with a single key, `body`.  Here's an
example:

```yaml
name: pull-request
on:
  pull_request:
    types: [opened, reopened, synchronize]
jobs:
  check-fast-forward:
    runs-on: ubuntu-latest

    permissions:
      contents: read
      # We appear to need write permission for both pull-requests and
      # issues in order to post a comment to a pull request.
      pull-requests: write
      issues: write

    steps:
      - name: Checking if fast forwarding is possible
        id: fast-forward
        uses: sequoia-pgp/fast-forward@main
        with:
          comment: false
      - name: Display comment
        env:
          COMMENT: ${{ steps.fast-forward.outputs.comment }}
        run: echo "The comment is... $COMMENT"
```

This would display something like:

```text
The comment is... {
  "body": "..."
}
```

Additional fields may be added to the JSON document in the future.
