#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "${BASH_TRACE:-0}" == "1" ]]; then
    set -o xtrace
fi

cd "$(dirname "$0")"

if [ $# -ne 5 ]; then
    echo "Missing required arguments"
    echo "Required four arguments: CODE_REPO_URL, DEV_BRANCH_NAME, RELEASE_BRANCH_NAME, HTML_REPO_URL, HTML_BRANCH_NAME"
    exit 1
fi

function has_remote_changes() {
    local BRANCH=$1
    
    git switch $BRANCH

    LOCAL_HASH=$(git rev-parse $BRANCH)
    echo $LOCAL_HASH
    REMOTE_HASH=$(git ls-remote origin -h refs/heads/$BRANCH | cut -f1)
    echo $REMOTE_HASH

    # COMMIT_COUNT_LOCAL=$(git rev-list --count $BRANCH)
    # COMMIT_COUNT_REMOTE=$(git rev-list HEAD..origin/$BRANCH --count)
    # echo $COMMIT_COUNT_LOCAL
    # echo $COMMIT_COUNT_REMOTE

    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        return 0 # Remote changes detected
    else
        return 1 # No remote changes
    fi
}

command_is_avilable() {
    command -v "$1" >/dev/null 2>&1
}

if command_is_avilable pytest; then
    echo "pytest is installed"
else
    echo "pytest is not installed"
    exit 1
fi

if command_is_avilable black; then
    echo "black is installed"
else
    echo "black is not installed"
    exit 1
fi

parse_repo_owner() {
    local REPO_URL=$1
    REPO_URL=${REPO_URL%.git}

    if [[ $REPO_URL =~ github\.com[:/](.+)/(.+) ]]; then
        local OWNER_NAME=${BASH_REMATCH[1]}
        echo "$OWNER_NAME"
    else
        echo "Invalid GitHub repository URL"
        exit 1
    fi
}

parse_repo_name() {
    local REPO_URL=$1
    REPO_URL=${REPO_URL%.git}

    if [[ $REPO_URL =~ github\.com[:/](.+)/(.+) ]]; then
        local REPO_NAME=${BASH_REMATCH[2]}
        echo "$REPO_NAME"
    else
        echo "Invalid GitHub repository URL"
        exit 1
    fi
}

contains_string_in_repo() {
    local REPO_URL=$1
    local SEARCH_STRING=$2

    if grep -q $SEARCH_STRING "${REPO_URL}/test_lib.py"; then
        echo "There are files in the repository with 'from pytest import' in their names"
    else
        echo "There are no test files in the repository"
        return 1
    fi
}


CODE_REPO_URL=$1
DEV_BRANCH_NAME=$2
RELEASE_BRANCH_NAME=$3
HTML_REPO_URL=$4
HTML_BRANCH_NAME=$5

REPOSITORY_PATH_CODE=$(mktemp --directory)


REPORT_REPOSITORY_OWNER=$(parse_repo_owner $HTML_REPO_URL)
REPOSITORY_NAME_REPORT=$(parse_repo_name $HTML_REPO_URL)

CODE_REPOSITORY_OWNER=$(parse_repo_owner $CODE_REPO_URL)
REPOSITORY_NAME_CODE=$(parse_repo_name $CODE_REPO_URL)
SUCCESS_DEV_BRANCH_TAG_NAME="${DEV_BRANCH_NAME}-ci-success"


function github_api_get_request() {
    curl --request GET \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --output "$2" \
        --silent \
        "$1"
    #--dump-header /dev/stderr \
}

function github_post_request() {
    curl --request POST \
        --header "Accept: application/vnd.github+json" \
        --header "Authorization: Bearer $GITHUB_PERSONAL_ACCESS_TOKEN" \
        --header "X-GitHub-Api-Version: 2022-11-28" \
        --header "Content-Type: application/json" \
        --silent \
        --output "$3" \
        --data-binary "@$2" \
        "$1"
    #--dump-header /dev/stderr \
}

function jq_update() {
    local IO_PATH=$1
    local TEMP_PATH=$(mktemp)
    shift
    cat $IO_PATH | jq "$@" >$TEMP_PATH
    mv $TEMP_PATH $IO_PATH
}

function pytest_status() {
    if pytest
    then
        PYTEST_RESULT=$?
        git tag -f develop-ci-success $(git rev-parse HEAD)
        echo "PYTEST SUCCEEDED $PYTEST_RESULT"


    else
        PYTEST_RESULT=$?
        echo "PYTEST FAILED $PYTEST_RESULT"
    fi
}

check_git_tag_exists() {
    local TAG="$1"
    git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}



# if has_remote_changes develop; then
#     git pull origin develop
# fi

# if has_remote_changes release; then
#     git pull origin release
# fi


# if pytest --verbose --html=$PYTEST_REPORT_PATH --self-contained-html
# then
#     PYTEST_RESULT=$?
#     echo "PYTEST SUCCEEDED $PYTEST_RESULT"
# else
#     PYTEST_RESULT=$?
#     echo "PYTEST FAILED $PYTEST_RESULT"
# fi
git clone $CODE_REPO_URL $REPOSITORY_PATH_CODE
FIRST_EXECUTION=0
while true; do
    REPOSITORY_PATH_REPORT=$(mktemp --directory)
    PYTEST_REPORT_PATH=$(mktemp)
    BLACK_OUTPUT_PATH=$(mktemp)
    BLACK_REPORT_PATH=$(mktemp)
    PYTEST_RESULT=0
    BLACK_RESULT=0
    

    if [ "$FIRST_EXECUTION" -eq 0 ] || has_remote_changes $DEV_BRANCH_NAME ]; then
        pushd $REPOSITORY_PATH_CODE
        FIRST_EXECUTION=1
        git tag
        git fetch --all
        # git pull origin develop
        git reset --hard origin/$DEV_BRANCH_NAME
    

        # git switch $DEV_BRANCH_NAME
        COMMIT_HASH=$(git rev-parse HEAD)
        AUTHOR_EMAIL=$(git log -n 1 --format="%ae" HEAD)

        UNIT_TESTS_EXISTS=false

        if contains_string_in_repo $REPOSITORY_PATH_CODE "from pytest import"; then
            UNIT_TESTS_EXISTS=true
        else
            UNIT_TESTS_EXISTS=false
            echo "Unit Tests is absent!!!"
        fi

        if [ "$UNIT_TESTS_EXISTS" = true ]; then
            if pytest --verbose --html=$PYTEST_REPORT_PATH --self-contained-html; then
                PYTEST_RESULT=$?
                git tag -f $SUCCESS_DEV_BRANCH_TAG_NAME $(git rev-parse HEAD)
                echo "PYTEST SUCCEEDED $PYTEST_RESULT"
            else
                PYTEST_RESULT=$?
                echo "PYTEST FAILED $PYTEST_RESULT"

                # pytest_status
                echo "hello"
                # git rev-parse --quiet --verify "refs/tags/$SUCCESS_DEV_BRANCH_TAG_NAME" >/dev/null
                # if [ $? -eq 0 ]; then
                #     echo "Tests Failed Activate Bisect"
                #     git bisect start
                #     git bisect bad HEAD
                #     git bisect good $(git rev-parse develop-ci-success)
                #     while git bisect next; do

                #         pytest_status
                #         if [ $PYTEST_RESULT -eq "0" ]; then
                #             git bisect good

                #         else
                #             git bisect bad
                #         fi

                #         if git bisect next | grep -q "is the first bad commit"; then
                #         # Extract the first bad commit hash
                #             # git bisect next
                #             first_bad_commit=$(git rev-parse HEAD)
                #             echo "First bad commit found: $first_bad_commit"
                #             break
                #         fi
                #     done
                # fi
                # git bisect reset
            fi

            echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"
        fi

        if black --check --diff *.py >$BLACK_OUTPUT_PATH; then
            BLACK_RESULT=$?
            echo "BLACK SUCCEEDED $BLACK_RESULT"
        else
            BLACK_RESULT=$?
            echo "BLACK FAILED $BLACK_RESULT"
            cat $BLACK_OUTPUT_PATH | pygmentize -l diff -f html -O full,style=solarized-light -o $BLACK_REPORT_PATH
        fi

        echo "\$PYTEST_RESULT = $PYTEST_RESULT \$BLACK_RESULT=$BLACK_RESULT"

        popd

        git clone $HTML_REPO_URL $REPOSITORY_PATH_REPORT

        pushd $REPOSITORY_PATH_REPORT

        git switch $HTML_BRANCH_NAME
        REPORT_PATH="${COMMIT_HASH}-$(date +%s)"
        mkdir --parents $REPORT_PATH
        if [ "$UNIT_TESTS_EXISTS" = true ]; then
            mv $PYTEST_REPORT_PATH "$REPORT_PATH/pytest.html"
        fi
        mv $BLACK_REPORT_PATH "$REPORT_PATH/black.html"
        git add $REPORT_PATH
        git commit -m "$COMMIT_HASH report."
        git push

        popd

        if ((($PYTEST_RESULT != 0) || ($BLACK_RESULT != 0))); then
            AUTHOR_USERNAME=""
            # https://docs.github.com/en/rest/search?apiVersion=2022-11-28#search-users
            RESPONSE_PATH=$(mktemp)
            github_api_get_request "https://api.github.com/search/users?q=$AUTHOR_EMAIL" $RESPONSE_PATH

            TOTAL_USER_COUNT=$(cat $RESPONSE_PATH | jq ".total_count")

            if [[ $TOTAL_USER_COUNT == 1 ]]; then
                USER_JSON=$(cat $RESPONSE_PATH | jq ".items[0]")
                AUTHOR_USERNAME=$(cat $RESPONSE_PATH | jq --raw-output ".items[0].login")
            fi

            REQUEST_PATH=$(mktemp)
            RESPONSE_PATH=$(mktemp)
            echo "{}" >$REQUEST_PATH

            BODY+="Automatically generated message
            
        "

            if (($PYTEST_RESULT != 0)); then
                if (($BLACK_RESULT != 0)); then
                    TITLE="${COMMIT_HASH::7} failed unit and formatting tests."
                    BODY+="${COMMIT_HASH} failed unit and formatting tests."
                    jq_update $REQUEST_PATH '.labels = ["ci-pytest", "ci-black"]'
                else
                    TITLE="${COMMIT_HASH::7} failed unit tests."
                    BODY+="${COMMIT_HASH} failed unit tests."
                    jq_update $REQUEST_PATH '.labels = ["ci-pytest"]'
                fi
            else
                TITLE="${COMMIT_HASH::7} failed formatting test."
                BODY+="${COMMIT_HASH} failed formatting test."
                jq_update $REQUEST_PATH '.labels = ["ci-black"]'
            fi

            if [ "$UNIT_TESTS_EXISTS" = true ]; then
                BODY+="Pytest report: https://${REPORT_REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/pytest.html
            
        "
            else
                BODY+="
                There are no unit tests
                
        "
            fi

            BODY+="Black report: https://${REPORT_REPOSITORY_OWNER}.github.io/${REPOSITORY_NAME_REPORT}/$REPORT_PATH/black.html
            
        "

            jq_update $REQUEST_PATH --arg title "$TITLE" '.title = $title'
            jq_update $REQUEST_PATH --arg body "$BODY" '.body = $body'

            if [[ ! -z $AUTHOR_USERNAME ]]; then
                jq_update $REQUEST_PATH --arg username "$AUTHOR_USERNAME" '.assignees = [$username]'
            fi

            # https://docs.github.com/en/rest/issues/issues?apiVersion=2022-11-28#create-an-issue
            github_post_request "https://api.github.com/repos/${CODE_REPOSITORY_OWNER}/${REPOSITORY_NAME_CODE}/issues" $REQUEST_PATH $RESPONSE_PATH
            #cat $RESPONSE_PATH
            cat $RESPONSE_PATH | jq ".html_url"
            rm $RESPONSE_PATH
            rm $REQUEST_PATH
        else
            echo "EVERYTHING OK, BYE!"
            pushd $REPOSITORY_PATH_CODE

            TAG_NAME=${DEV_BRANCH_NAME}--ci-success
            git tag $TAG_NAME
            # git push origin TAG_NAME
            git tag
            popd
        fi
        sleep 15
        rm -rf $REPOSITORY_PATH_REPORT
        rm -rf $PYTEST_REPORT_PATH
        rm -rf $BLACK_REPORT_PATH
    fi
done

rm -rf $REPOSITORY_PATH_CODE
