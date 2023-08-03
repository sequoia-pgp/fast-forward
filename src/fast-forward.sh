#! /bin/bash

# This can be called with an issue or pull request context:
#
# https://docs.github.com/en/webhooks-and-events/webhooks/webhook-events-and-payloads#issue_comment
# https://docs.github.com/en/webhooks-and-events/webhooks/webhook-events-and-payloads#pull_request
#
# If --merge is specified, then actually does the fast forward.
# Otherwise, just reports if fast forwarding is possible.
#
# This expects the environment variables GITHUB_EVENT_PATH,
# GITHUB_ACTOR, and GITHUB_TOKEN to be set.
#
# If the current directory doesn't contain a checkout of the git
# repository, it is cloned.  If the git repository doesn't contain the
# commits from the PR, they are automatically fetched.
#
# The output is written to the file specified by GITHUB_STEP_SUMMARY,
# see:
#
# https://github.blog/2022-05-09-supercharging-github-actions-with-job-summaries/
#
# And a comment is posted (if possible).

set -e

# Set to 1 to get some debugging information dumped to stderr.
DEBUG=0

if test "x$GITHUB_EVENT_PATH" = x
then
    echo "GITHUB_EVENT_PATH environment variable must be set." >&2
    exit 1
fi

if test $DEBUG -gt 0
then
    {
        echo env
        env
        echo GITHUB_ENV: $GITHUB_ENV
        cat $GITHUB_ENV
        echo GITHUB_EVENT_PATH: $GITHUB_EVENT_PATH
        cat $GITHUB_EVENT_PATH
    } >&2
fi

# All of the event properties are held under the github.event context,
# which is also available as JSON-encoded data in the file
# $GITHUB_EVENT_PATH.
#
# For an issue_comment event, see:
#
# https://docs.github.com/en/webhooks-and-events/webhooks/webhook-events-and-payloads#issue_comment

# Returns the value of the first key in the github.event data
# structure that is not null.
#
# Example:
#
#   $(github_event .issue.pull_request.url .pull_request.url)
#
# Returns github.event.issue.pull_request.url or, if that is not set,
# github.event.pull_request.url.  If neither is set, returns the empty
# string.
function github_event {
    while test $# -gt 0
    do
        VALUE=$(jq -r "$1" <$GITHUB_EVENT_PATH)
        if test "x$VALUE" != xnull
        then
            echo "$VALUE"
            break
        fi

        shift
    done
}

# Like github_event, but for the github.event.pull_request context.
GITHUB_PR=$(mktemp)
function github_pull_request {
    if ! test -s "$GITHUB_PR"
    then
        # Get the PR metadata.

        # If we have a github.event.pull_request object, use it.
        github_event .pull_request >>$GITHUB_PR

        if ! test -s "$GITHUB_PR"
        then
            # It seems we don't.  Fetch it.
            PR_URL="$(github_event .issue.pull_request.url)"
            if test "x$PR_URL" = x
            then
                echo "Unable to find pull request's context."
                exit 1
            fi

            curl --silent --show-error --location \
                 -X GET \
                 -H "Accept: application/vnd.github+json" \
                 -H "Authorization: Bearer $GITHUB_TOKEN" \
                 -H "X-GitHub-Api-Version: 2022-11-28" \
                 "$PR_URL" >$GITHUB_PR
        fi

        if test $DEBUG -gt 0
        then
            {
                echo "pull_request ($GITHUB_PR):"
                cat "$GITHUB_PR"
            } >&2
        fi
    fi

    while test $# -gt 0
    do
        VALUE=$(jq -r "$1" <$GITHUB_PR)
        if test "x$VALUE" != xnull
        then
            echo "$VALUE"
            break
        fi

        shift
    done
}

# Repository is ${{ github.repository }}
# Triggered by issue ${{ github.event.issue.number }}

LOG=$(mktemp)
{
    echo "Triggered from $(github_event .comment.html_url .pull_request.html_url) by $GITHUB_ACTOR."
    echo

    # The symbolic name.
    BASE_REF=$(github_pull_request .base.ref)
    # github.event.pull_request.base.sha is the value of the branch at
    # the time the PR was created, and might not be current.
    # BASE_SHA=$(github_pull_request .base.sha)
    BASE_SHA="$(test -d .git && git rev-parse origin/$BASE_REF 2>/dev/null || true)"

    if test x$BASE_SHA = x
    then
        # Check out the repository.
        CLONE_URL=$(github_pull_request .base.repo.clone_url)

        # Cache the credentials.
        git config --global credential.helper store
        {
            echo "url=$CLONE_URL"
            echo "username=$GITHUB_ACTOR"
            echo "password=$GITHUB_TOKEN"
        } | git credential approve

        CLONE_URL="${CLONE_URL%://*}://${GITHUB_ACTOR}@${CLONE_URL#*://}"
        git clone --quiet --single-branch --branch "$BASE_REF" "$CLONE_URL" .

        BASE_SHA="$(git rev-parse origin/$BASE_REF 2>/dev/null)"
    fi

    PR_REF=$(github_pull_request .head.ref)
    PR_SHA=$(github_pull_request .head.sha)

    if ! git cat-file -e "$PR_SHA" 2>/dev/null
    then
        # Our git repository only has the content from the main
        # repository.  If the PR is from a fork, then we need to fetch
        # its contents too.
        CLONE_URL=$(github_pull_request .head.repo.clone_url)

        # Cache the credentials.
        git config --global credential.helper store
        {
            echo "url=$CLONE_URL"
            echo "username=$GITHUB_ACTOR"
            echo "password=$GITHUB_TOKEN"
        } | git credential approve

        CLONE_URL="${CLONE_URL%://*}://${GITHUB_ACTOR}@${CLONE_URL#*://}"
        git fetch --quiet "$CLONE_URL" "$PR_SHA"
    fi

    # Name the remote branch so that it looks pretty.
    git branch -f "pull_request/$PR_REF" "$PR_SHA"

    echo "Trying to fast forward \`$BASE_REF\` ($BASE_SHA):"
    echo
    echo '```shell'
    git log --decorate=short -n 1 "$BASE_SHA"
    echo '```'
    echo
    echo "to \`$PR_REF\` ($PR_SHA):"
    echo
    echo '```shell'
    git log --decorate=short -n 1 "$PR_SHA"
    echo '```'
    echo

    if ! git merge-base --is-ancestor "$BASE_SHA" "$PR_SHA"
    then
        # No luck.  The PR needs to be rebased.

        echo -n "Can't fast forward."
        echo -n " \`$BASE_REF\` $BASE_SHA"
        echo -n " is not a direct ancestor of"
        echo -n " \`$PR_REF\` $PR_SHA."

        MERGE_BASE=$(git merge-base "$BASE_SHA" "$PR_SHA" || true)
        if test x"$MERGE_BASE" = x
        then
            echo " Branches don't appear to have a common ancestor."
        else
            echo " Branches appear to have diverged at $MERGE_BASE:"
            echo
            echo '```shell'
            git log --pretty=oneline --graph \
                "^$MERGE_BASE^" "$BASE_SHA" "$PR_SHA"
            git log --decorate=short -n 1 "$MERGE_BASE"
            echo '```'
            echo
            echo "Rebase locally, and then force push to \`$PR_REF\`."
        fi
    elif test "x$1" = "x--merge"
         # Check that the user is allowed and then fast forward the
         # target!

        # https://docs.github.com/en/rest/collaborators/collaborators?apiVersion=2022-11-28#check-if-a-user-is-a-repository-collaborator
        COLLABORATORS_URL="$(github_event .repository.collaborators_url)"
        COLLABORATORS_URL="${COLLABORATORS_URL%\{/collaborator\}}/$(github_event .sender.login)"
        if curl --silent --show-error --location \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer $GITHUB_TOKEN" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                --head \
                "$COLLABORATORS_URL" \
                | awk '
              /^HTTP/ {
                if ($2 == "204") {
                  exit 0;
                } else {
                  print "Access denied: "$2;
                  exit 1;
                }
              }

              // { exit 1; }'
        then
            echo '```shell'
            (
                PS4='$ '
                set -x
                git push origin "$PR_SHA:$BASE_REF"
            )
            echo '```'
        else
            echo -n "Sorry @$(github_event .sender.login), only those with"
            echo " write access to this repository can merge pull requests."
        fi
    else
        # We're just checking.

        echo -n "If you have write access to the target repository,"
        echo -n " you can add a comment with \`/fast-forward\` to"
        echo -n " fast forward"
        echo " \`$BASE_REF\` to \`$PR_REF\`."
    fi
} 2>&1 | tee -a $GITHUB_STEP_SUMMARY "$LOG"

COMMENT=$(mktemp)
jq -n --rawfile log "$LOG" '{ "body": $log }' >"$COMMENT"

COMMENTS_URL="$(github_pull_request .comments_url)"
if test "x$COMMENTS_URL" != x
then
    echo "Posting comment to $COMMENTS_URL."
    curl --silent --show-error --location \
         -X POST \
         -H "Accept: application/vnd.github+json" \
         -H "Authorization: Bearer $GITHUB_TOKEN" \
         -H "X-GitHub-Api-Version: 2022-11-28" \
         "$COMMENTS_URL" \
         -d "@$COMMENT"
else
    echo "Can't post a comment: github.event.pull_request.comments_url is not set." | tee -a $GITHUB_STEP_SUMMARY
fi
