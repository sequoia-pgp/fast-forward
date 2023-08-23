This repository contains several GitHub actions that can help users of
your repository authenticate signed commits.

Unfortunately using signed commits with GitHub requires a bit of work
due to how GitHub merges commits: even when a pull request could be
merged by fast forwarding the target branch, GitHub rewrites the
commits (specifically, it updates the committer field, and resigns the
commits).  Since the commits are modified, the original signatures are
invalidated, and stripped.

It is possible to push changes from a pull request directly to the
target branch after any checks have passed.  But, this is
inconvenient.  The `check-fast-forward` and `fast-forward` actions
make it possible to do this directly from a comment on the pull
request.

`check-fast-forward` checks if a pull request can be merged whenever a
pull request is opened or updated, and adds a comment on the pull
request indicating if this is the case, or if the pull request needs
to be rebased.  It can be enabled as follows by adding
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

To actually fast-forward a branch when an authorized user adds a
comment containing `/fast-forward` to the pull request, add
`.github/workflows/fast-forward.yml` to your repository with the
following contents:

```yaml
name: fast-forward
on:
  issue_comment:
    types: [created, edited]
jobs:
  fast-forward:
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

Note: `fast-forward` is careful to check that the user who triggered
the workflow is authorized to push to the repository.
