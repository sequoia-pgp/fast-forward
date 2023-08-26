#! /bin/bash

# This script can be run locally or via GitHub actions.  If you want
# to run it locally, just run the script and it will tell you what
# variables you need to set.

# Where to run the test.
OWNER=${OWNER:-sequoia-pgp}
REPO=${REPO:-fast-forward-unit-tests}

# To generate a personal access token, go to your profile and then:
#
#   - Top-Right Menu
#   - Settings
#   - Developer Settings
#   - Personal access tokens
#   - Tokens (classic)
#   - Generate a personal access token
#
# Create a token with "repo" permission.
if test "x$GITHUB_TOKEN" = x -a "x$FAST_FORWARD_UNIT_TESTS_TOKEN" = x
then
    echo "Either the GITHUB_TOKEN or the FAST_FORWARD_UNIT_TESTS_TOKEN environment variable needs to be set."
    exit 1
fi

# Prefer FAST_FORWARD_UNIT_TESTS_TOKEN (which is a secret known to the
# fast-forward repository), but when that is not set try GITHUB_TOKEN,
# which works with personal access tokens, and when the action is run
# from the same repository.
TOKEN="${FAST_FORWARD_UNIT_TESTS_TOKEN:-$GITHUB_TOKEN}"

if test x$GITHUB_ACTOR = x
then
    echo "GITHUB_ACTOR environment variable (your GitHub user name) is not set, but is required."
    exit 1
fi

TEMPFILES=$(mktemp)
echo -n "$TEMPFILES" >> "$TEMPFILES"
function maketemp {
    F=$(mktemp $*)
    echo -n " $F" >> $TEMPFILES
    echo "$F"
}
function maketemp_exit {
    TEMPFILES=$(cat $TEMPFILES)
    if test x"$TEMPFILES" != x
    then
        echo -e "Clean up temporary files by running:\n  $ rm -rf $TEMPFILES"
    fi
}
trap maketemp_exit EXIT

set -ex

# Files from the fast-forward repository that we copy over.
FILES=".github/workflows/fast-forward.yml
     .github/workflows/pull_request.yml"

FAST_FORWARD_REPO=$(git rev-parse --show-toplevel)
for f in $FILES
do
    if ! test -e "$FAST_FORWARD_REPO/$f"
    then
        echo "Missing \"$f\".  Are you really in the fast-forward repo?"
        exit 1
    fi
done

echo "::group::Initializing scratch repository"

D=$(maketemp -d)
echo "Scratch directory: $D"
cd $D

git init --initial-branch main .
git config user.name "Fast Forward Unit Test"
git config user.email "neal@sequoia-pgp.org"

git config credential.helper store
{
    echo "url=https://$GITHUB_ACTOR@github.com/$OWNER/$REPO.git"
    echo "username=$GITHUB_ACTOR"
    echo "password=$TOKEN"
} | git credential approve

git remote add origin "https://$GITHUB_ACTOR@github.com/$OWNER/$REPO.git"

echo "::endgroup::"

echo "::group::Add first batch of commits"

# Add the workflow files.
for f in $FILES
do
    mkdir -p $(dirname $f)
    cp "$FAST_FORWARD_REPO/$f" "$f"
    git add "$f"
done

git commit -m 'Initial commit' --no-gpg-sign

echo foo >> foo
git add foo
git commit -m 'Adding foo' --no-gpg-sign

BASE=fast-forward-test-0$RANDOM
git push origin main:$BASE

# Reset to the first commit so that the PR can't be fast forwarded.
git reset --hard HEAD^

echo "::endgroup::"

# Create a new commit, push it to a different branch.
echo "::group::Add second batch of commits"

echo $RANDOM > bar
git add bar
git commit -m 'Adding bar' --no-gpg-sign

PR=$BASE-pr
git push origin main:$PR

echo "::endgroup::"

echo "::group::Open pull request"

# Create a pull request.
OPEN_PR_RESULT=$(maketemp)
curl --silent --show-error --output $OPEN_PR_RESULT -L \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$OWNER/$REPO/pulls \
    -d '{
      "title":"/fast-forward unit test",
      "body":"This is a test, this is only a test!",
      "head":"'"$PR"'",
      "base":"'"$BASE"'"
    }'

PR_URL=$(jq -r ".url" < $OPEN_PR_RESULT)
if test "x$PR_URL" = xnull
then
    echo "Couldn't get PR's URL"
    echo "Server's response:"
    cat "$OPEN_PR_RESULT"
    exit 1
fi
PR_NUMBER=$(jq -r ".number" < $OPEN_PR_RESULT)
if test "x$PR_NUMBER" = xnull
then
    echo "Couldn't get PR's number"
    echo "Server's response:"
    cat "$OPEN_PR_RESULT"
    exit 1
fi

echo "::endgroup::"

echo "Pull request: https://github.com/$OWNER/$REPO/pull/$PR_NUMBER"

# Returns the body of the nth comment (zero-based index).  To return
# the second comment, do:
#
#  wait_for_comment 1
#
# If the comment is not present, this polls for a while.
function wait_for_comment {
    N=$1
    case "$N" in
        [0-9]) :;;
        *)
            echo "Invalid comment number: $N" >&2
            exit 1
            ;;
    esac

    COMMENTS_RESULT=$(maketemp)
    echo "Waiting for comment #$N..." >&2
    for i in $(seq 20 -1 0)
    do
        if test $i -eq 0
        then
            echo "Timeout waiting for comment" >&2
            cat "$COMMENTS_RESULT" >&2
            exit 1
        fi
        sleep 3

        curl --silent --show-error --output "$COMMENTS_RESULT" -L \
             -H "Accept: application/vnd.github+json" \
             -H "Authorization: Bearer $TOKEN" \
             -H "X-GitHub-Api-Version: 2022-11-28" \
             https://api.github.com/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments

        COMMENT=$(jq -r .[$N].body <"$COMMENTS_RESULT")
        if test "x$COMMENT" = xnull
        then
            # The job hasn't completed yet.
            continue
        else
            echo "$COMMENT"
            break
        fi
    done
}

echo "::group::Check that the check-fast-forward action ran, and said no"

COMMENT=$(wait_for_comment 0)
if echo "$COMMENT" | grep -q 'is not a direct ancestor of'
then
    echo check-fast-forward worked.
else
    echo "Unexpected comment in response to push, did check-fast-forward change?"
    echo "Comment:"
    echo "$COMMENT"
    exit 1
fi

echo "::endgroup::"

echo "::group::Post a /fast-forward comment to try to fast forward the pull request"

curl --silent --show-error -L \
     -X POST \
     -H "Accept: application/vnd.github+json" \
     -H "Authorization: Bearer $TOKEN" \
     -H "X-GitHub-Api-Version: 2022-11-28" \
     https://api.github.com/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
     -d '{ "body":"/fast-forward this..." }'

COMMENT=$(wait_for_comment 2)
if echo "$COMMENT" | grep -q 'is not a direct ancestor of'
then
    echo check-fast-forward worked.
else
    echo "Unexpected comment in response to /fast-forward, did fast-forward change?"
    echo "Comment:"
    echo "$COMMENT"
    exit 1
fi

echo "::endgroup::"

echo "::group::Rebase PR so that fast forwarding is possible"

git rebase "origin/$BASE" --no-gpg-sign
git push --force origin main:$PR

echo "::endgroup::"

echo "::group::Check that the check-fast-forward action ran, and said yes"

COMMENT=$(wait_for_comment 3)
if echo "$COMMENT" | grep -q 'you can add a comment with `/fast-forward` to fast forward'
then
    echo check-fast-forward worked.
else
    echo "Unexpected comment in response to push, did check-fast-forward change?"
    echo "Comment:"
    echo "$COMMENT"
    exit 1
fi

echo "::endgroup::"

echo "::group::Post a /fast-forward comment to fast forward the pull request"

curl --silent --show-error -L \
     -X POST \
     -H "Accept: application/vnd.github+json" \
     -H "Authorization: Bearer $TOKEN" \
     -H "X-GitHub-Api-Version: 2022-11-28" \
     https://api.github.com/repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
     -d '{ "body":"We should /fast-forward this..." }'

COMMENT=$(wait_for_comment 5)
if echo "$COMMENT" | grep -q 'Fast forwarding `'"$BASE"'`'
then
    echo check-fast-forward worked.
else
    echo "Unexpected comment in response to /fast-forward, did fast-forward change?"
    echo "Comment:"
    echo "$COMMENT"
    exit 1
fi

echo "::endgroup::"

# Make sure the base was fast forwarded by checking that its sha is
# now identical to HEAD.
echo "::group::Check that the remote branch was fast forwarded"

git fetch -a origin $BASE

BASE_SHA=$(git rev-parse origin/$BASE)
if test x$BASE_SHA = x
then
    echo "Base branch disappeared?!?"
    exit 1
fi
HEAD_SHA=$(git rev-parse HEAD)
if test "x$BASE_SHA" != "x$HEAD_SHA"
then
    echo "Base was not fast forwarded to HEAD: $BASE_SHA != $HEAD_SHA!"
    exit 1
fi

echo "Pull request was fast forwarded!"

echo "::endgroup::"

echo "::group::Check that the PR is closed"

MERGED_PR_RESULT=$(maketemp)
curl --silent --show-error --output $MERGED_PR_RESULT -L \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/$OWNER/$REPO/issues/$PR_NUMBER

STATE=$(jq -r .state <"$MERGED_PR_RESULT")
if test "x$STATE" != xclosed
then
    echo "PR was not closed (state: '$STATE')"
    cat $MERGED_PR_RESULT
    exit 1
fi

echo "::endgroup::"

# Clean up on success.
rm -rf $D
