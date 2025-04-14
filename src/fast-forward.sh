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
case "${DEBUG:-0}" in
    0 | false | FALSE) DEBUG=0;;
    [0-9] | true | TRUE) DEBUG=1;;
    *)
        echo "Warning: Invalid value ('$DEBUG') for DEBUG." >&2;
        DEBUG=1
        ;;
esac

# Set to true to post a comment to the issue.
case "${COMMENT:-true}" in
    0 | never | false | FALSE) COMMENT=never;;
    1 | always | true | TRUE) COMMENT=always;;
    on-error) COMMENT=on-error;;
    *)
        echo "Warning: Invalid value ('$COMMENT') for COMMENT." >&2;
        COMMENT=on-error
        ;;
esac

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

# Set to 0 if everything is okay.  Set to 1, if fast forwarding is not
# possible or fails.  This is a file to simplify setting this from a
# subshell.
EXIT_CODE=$(mktemp)
echo 1 >$EXIT_CODE

LOG=$(mktemp)
{
    echo "Triggered from $(github_event .comment.html_url .pull_request.html_url) by [@&ZeroWidthSpace;$GITHUB_ACTOR](https://github.com/$GITHUB_ACTOR)."
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

    if test "x$1" = "x--merge"
    then
        echo -n "Trying to "
    else
        echo -n "Checking if we can "
    fi
    echo " fast forward \`$BASE_REF\` ($BASE_SHA) to \`$PR_REF\` ($PR_SHA)."

    echo
    echo "Target branch (\`$BASE_REF\`):"
    echo
    echo '```shell'
    git log --decorate=short -n 1 "$BASE_SHA"
    echo '```'
    echo
    echo "Pull request (\`$PR_REF\`):"
    echo
    echo '```shell'
    git log --decorate=short -n 1 "$PR_SHA"
    echo '```'

    if ! git merge-base --is-ancestor "$BASE_SHA" "$PR_SHA"
    then
        # No luck.  The PR needs to be rebased.

        echo -n "Can't fast forward \`$BASE_REF\` ($BASE_SHA) to"
        echo -n " \`$PR_REF\` ($PR_SHA)."
        echo -n " \`$BASE_REF\` ($BASE_SHA) is not a direct ancestor of"
        echo -n " \`$PR_REF\` ($PR_SHA)."

        MERGE_BASE=$(git merge-base "$BASE_SHA" "$PR_SHA" || true)
        if test x"$MERGE_BASE" = x
        then
            echo " Branches don't appear to have a common ancestor."
        else
            echo " Branches appear to have diverged at $MERGE_BASE:"
            echo
            echo '```shell'

            # We don't want to displays the commits before the merge
            # base.  We need to be careful though: if the merge base
            # is a root (i.e., it has no parents), then $MERGE_BASE^
            # is not a valid reference.
            if test x$(git cat-file -t "$MERGE_BASE^") = xcommit
            then
                EXCLUDE="^$MERGE_BASE^"
            else
                EXCLUDE=
            fi

            git log --pretty=oneline --graph \
                $EXCLUDE "$BASE_SHA" "$PR_SHA"
            echo
            git log --decorate=short -n 1 "$MERGE_BASE"
            echo '```'
        fi
        echo
        echo "Rebase locally, and then force push to \`$PR_REF\`."
    elif test "x$1" = "x--merge"
    then
        # Check that the user is allowed and then fast forward the
        # target!

        # https://docs.github.com/en/rest/collaborators/collaborators?apiVersion=2022-11-28#get-repository-permissions-for-a-user
        COLLABORATORS_URL="$(github_event .repository.collaborators_url)"
        COLLABORATORS_URL="${COLLABORATORS_URL%\{/collaborator\}}"

        PERM=$(mktemp)
        curl --silent --show-error -o "$PERM" --location \
             -H "Accept: application/vnd.github+json" \
             -H "Authorization: Bearer $GITHUB_TOKEN" \
             -H "X-GitHub-Api-Version: 2022-11-28" \
             $COLLABORATORS_URL/$(github_event .sender.login)/permission

        if test "x$(jq -r .user.permissions.push < $PERM)" = xtrue
        then
            if test "x$2" = "xmerge-commit"
            then
                # Retrieve the user's details (comment sender username and email)
                # required for merge-commit metadata.
                USER_NAME="$(github_event .sender.login)"
                # Email pattern vampirised from the checkout action
                # (https://github.com/actions/checkout/blob/main/README.md):
                #   {user.id}+{user.login}@users.noreply.github.com
                USER_EMAIL="$(github_event .sender.id)+${USER_NAME}@users.noreply.github.com"

                echo "Merging \`$PR_REF\` ($PR_SHA) into \`$BASE_REF\` ($BASE_SHA)."

                if test "$(git rev-parse HEAD)" != "${BASE_SHA}"
                then
                    git checkout "${BASE_REF}"
                fi

                MESSAGE=$(mktemp)
                PR_NUMBER="$(github_pull_request .number)"
                PR_HTML_URL="$(github_pull_request .html_url)"
                # debug stuff
                cat $GITHUB_EVENT
                {
                    case "${MERGE_COMMIT_CONTENT}"  in
                        pr-title-and-body)
                            # Message contains PR's title and PR's description
                            # (similar to GitHub's option "PR title and description" +
                            # the PR's references)
                            echo "Merge #${PR_NUMBER}: $(github_pull_request .title)"
                            echo ""
                            echo "* ${PR_HTML_URL}"
                            echo "* from ${PR_REF} into ${BASE_REF}"
                            echo ""
                            github_pull_request .body
                            ;;
                        pr-title)
                            # Message only contains PR's title
                            # (similar to GitHub's option "PR title" + the PR's references)
                            echo "$(github_pull_request .title) (#${PR_NUMBER})"
                            echo ""
                            echo "* ${PR_HTML_URL}"
                            echo "* from ${PR_REF} into ${BASE_REF}"
                            ;;
                        *)
                            # Default merge commit message (similar to GitHub's default)
                            echo "Merge pull request #$(github_pull_request .number) from ${PR_REF}"
                            echo ""
                            github_pull_request .title
                            ;;
                    esac
                } > "${MESSAGE}"
                echo '```shell'
                (
                    PS4='$ '
                    set -x
                    git \
                        -c user.name="${USER_NAME}" \
                        -c user.email="${USER_EMAIL}" \
                        merge --no-ff --into-name "${BASE_REF}" --file "${MESSAGE}" "${PR_SHA}"
                    git push origin "${BASE_REF}"
                )
                echo '```'
                rm $MESSAGE
                echo 0 >$EXIT_CODE

            else
                echo -n "Fast forwarding \`$BASE_REF\` ($BASE_SHA) to"
                echo " \`$PR_REF\` ($PR_SHA)."

                echo '```shell'
                (
                    PS4='$ '
                    set -x
                    git push origin "$PR_SHA:$BASE_REF"
                )
                echo '```'
                echo 0 >$EXIT_CODE
            fi
        else
            echo -n "Sorry @$(github_event .sender.login),"
            echo -n " it is possible to fast forward \`$BASE_REF\` ($BASE_SHA)"
            echo -n " to \`$PR_REF\` ($PR_SHA), but you don't appear to have"
            echo    " permission to push to this repository."
        fi
    else
        # We're just checking if fast forwarding is possible.

        echo -n "It is possible to fast forward \`$BASE_REF\` ($BASE_SHA)"
        echo -n " to \`$PR_REF\` ($PR_SHA).  If you have write access to the"
        echo -n " target repository, you can add a comment with"
        echo -n " \`/fast-forward\` to fast forward \`$BASE_REF\` to"
        echo    " \`$PR_REF\`."
        echo 0 >$EXIT_CODE
    fi
} 2>&1 | tee -a $GITHUB_STEP_SUMMARY "$LOG"

COMMENT_CONTENT=$(mktemp)
jq -n --rawfile log "$LOG" '{ "body": $log }' >"$COMMENT_CONTENT"

# Set the comment output variable.
{
    # https://docs.github.com/en/actions/using-workflows/workflow-commands-for-github-actions#multiline-strings
    echo "comment<<EOF_$COMMENT_CONTENT"
    cat "$COMMENT_CONTENT"
    echo "EOF_$COMMENT_CONTENT"
} | tee -a "$GITHUB_OUTPUT"

if test "x$COMMENT" = xalways \
        -o \( "x$COMMENT" = xon-error -a "$(cat $EXIT_CODE)" -ne 0 \)
then
    # Post the comment.
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
             -d "@$COMMENT_CONTENT"
    else
        echo "Can't post a comment: github.event.pull_request.comments_url is not set." | tee -a $GITHUB_STEP_SUMMARY
    fi
else
    echo "Not posting comment."
fi

exit $(cat $EXIT_CODE)
