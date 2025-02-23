#!/usr/bin/env bash

#
# TYPO3 core test runner based on docker and docker-compose.
#

# Function to write a .env file in Build/testing-docker
# This is read by docker-compose and vars defined here are
# used in Build/testing-docker/docker-compose.yml
setUpDockerComposeDotEnv() {
    # Delete possibly existing local .env file if exists
    [ -e .env ] && rm .env
    # Set up a new .env file for docker-compose
    {
        echo "COMPOSE_PROJECT_NAME=${PROJECT_NAME}"
        # To prevent access rights of files created by the testing, the docker image later
        # runs with the same user that is currently executing the script. docker-compose can't
        # use $UID directly itself since it is a shell variable and not an env variable, so
        # we have to set it explicitly here.
        echo "HOST_UID=`id -u`"
        # Your local user
        echo "ROOT_DIR=${ROOT_DIR}"
        echo "HOST_USER=${USER}"
        echo "DOCKER_PHP_IMAGE=${DOCKER_PHP_IMAGE}"
        echo "IMAGE_PREFIX=${IMAGE_PREFIX}"
        echo "SCRIPT_VERBOSE=${SCRIPT_VERBOSE}"
        echo "CGLCHECK_DRY_RUN=${CGLCHECK_DRY_RUN}"
    } > .env
}

# Load help text into $HELP
read -r -d '' HELP <<EOF
EXT:reference-coreapi test runner. Check code styles, lint PHP files and some other details.

Recommended docker version is >=20.10 for xdebug break pointing to work reliably, and
a recent docker-compose (tested >=1.21.2) is needed.

Usage: $0 [options] [file]

No arguments: Run all checks with PHP 8.1

Options:
    -s <...>
        Specifies which test suite to run
            - checkRst: test .rst files for integrity
            - cgl: cgl test and fix all php files
            - composerUpdate: "composer update", handy if host has no PHP
            - lint: PHP linting
            - rector: Apply Rector rules

    -p <8.1|8.2>
        Specifies the PHP minor version to be used
            - 8.1 (default): use PHP 8.1
            - 8.2: use PHP 8.2

    -u
        Update existing typo3/core-testing-*:latest docker images. Maintenance call to docker pull latest
        versions of the main php images. The images are updated once in a while and only the youngest
        ones are supported by core testing. Use this if weird test errors occur. Also removes obsolete
        image versions of typo3/core-testing-*.

    -v
        Enable verbose script output. Shows variables and docker commands.

    -h
        Show this help.

Examples:
    # Run checks using PHP 8.1
    ./Build/Scripts/runTests.sh
EOF

# Test if docker-compose exists, else exit out with error
if ! type "docker-compose" > /dev/null; then
  echo "This script relies on docker and docker-compose. Please install" >&2
  exit 1
fi

# Go to the directory this script is located, so everything else is relative
# to this dir, no matter from where this script is called.
THIS_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
cd "$THIS_SCRIPT_DIR" || exit 1

RUNTESTS_FILE="${PWD}"
while [ -h "${RUNTESTS_FILE}" ]; do # resolve ${SCRIPT_FILE} until the file is no longer a symlink
  TMPDIR="$( cd -P "$( dirname "${RUNTESTS_FILE}" 2>/dev/null )" && pwd )"
  RUNTESTS_FILE="$(readlink "${RUNTESTS_FILE}" 2>/dev/null )"
  [[ ${RUNTESTS_FILE} != /* ]] && SOURCE="${TMPDIR}/${RUNTESTS_FILE}"
done
PROJECT_DIR="$( cd -P "$( dirname "${RUNTESTS_FILE}" 2>/dev/null )/.." && pwd )"
# get project folder name, lowercased and spaces replaced with dashes
PROJECT_PARENT_NAME="$( basename $( dirname ${PROJECT_DIR} 2>/dev/null ) 2>/dev/null | tr 'A-Z' 'a-z' | tr ' ' '-' )"
[[ -z "${PROJECT_PARENT_NAME}" ]] && PROJECT_PARENT_NAME="no-parent-folder"
PROJECT_NAME="$( echo \"runTests-${PROJECT_PARENT_NAME}-$( basename ${PROJECT_DIR} 2>/dev/null | tr 'A-Z' 'a-z' | tr ' ' '-' )\" | tr '[:upper:]' '[:lower:]')"
# using $$ would add the process id to the string. May be breaking, until proper traps have been implemented to
# ensure docker services are correctly cleaned on errors/exit
#PROJECT_NAME="${PROJECT_NAME//[[:blank:]]/}-$$"
PROJECT_NAME="${PROJECT_NAME//[[:blank:]]/}"

# Go to directory that contains the local docker-compose.yml file
cd ../testing-docker || exit 1

# Option defaults
if ! command -v realpath &> /dev/null; then
  echo "This script works best with realpath installed" >&2
  ROOT_DIR="${PWD}/../../"
else
  ROOT_DIR=`realpath ${PWD}/../../`
fi
TEST_SUITE="cgl"
PHP_VERSION="8.1"
SCRIPT_VERBOSE=0
CGLCHECK_DRY_RUN=""
IMAGE_PREFIX="ghcr.io/typo3/"

# Option parsing
# Reset in case getopts has been used previously in the shell
OPTIND=1
# Array for invalid options
INVALID_OPTIONS=();
# Simple option parsing based on getopts (! not getopt)
while getopts ":s:p:nhuv" OPT; do
    case ${OPT} in
        s)
            TEST_SUITE=${OPTARG}
            ;;
        p)
            PHP_VERSION=${OPTARG}
            ;;
        h)
            echo "${HELP}"
            exit 0
            ;;
        n)
            CGLCHECK_DRY_RUN="-n"
            ;;
        u)
            TEST_SUITE=update
            ;;
        v)
            SCRIPT_VERBOSE=1
            ;;
        \?)
            INVALID_OPTIONS+=(${OPTARG})
            ;;
        :)
            INVALID_OPTIONS+=(${OPTARG})
            ;;
    esac
done

# Exit on invalid options
if [ ${#INVALID_OPTIONS[@]} -ne 0 ]; then
    echo "Invalid option(s):" >&2
    for I in "${INVALID_OPTIONS[@]}"; do
        echo "-"${I} >&2
    done
    echo >&2
    echo "${HELP}" >&2
    exit 1
fi

# Move "8.1" to "php81", the latter is the docker container name
DOCKER_PHP_IMAGE=`echo "php${PHP_VERSION}" | sed -e 's/\.//'`

# Suite execution
case ${TEST_SUITE} in
    checkRst)
        setUpDockerComposeDotEnv
        docker-compose run check_rst
        SUITE_EXIT_CODE=$?
        docker-compose down
        ;;
    cgl)
        # Active dry-run for cgl needs not "-n" but specific options
        if [[ ! -z ${CGLCHECK_DRY_RUN} ]]; then
            CGLCHECK_DRY_RUN="--dry-run --diff"
        fi
        setUpDockerComposeDotEnv
        docker-compose run cgl
        SUITE_EXIT_CODE=$?
        docker-compose down
        ;;
    composerUpdate)
        setUpDockerComposeDotEnv
        docker-compose run composer_update
        SUITE_EXIT_CODE=$?
        docker-compose down
        ;;
    lint)
        setUpDockerComposeDotEnv
        docker-compose run lint
        SUITE_EXIT_CODE=$?
        docker-compose down
        ;;
    update)
        # pull typo3/core-testing-*:latest versions of those ones that exist locally
        docker images ${IMAGE_PREFIX}core-testing-*:latest --format "{{.Repository}}:latest" | xargs -I {} docker pull {}
        # remove "dangling" typo3/core-testing-* images (those tagged as <none>)
        docker images ${IMAGE_PREFIX}core-testing-* --filter "dangling=true" --format "{{.ID}}" | xargs -I {} docker rmi {}
        ;;
    *)
        echo "Invalid -s option argument ${TEST_SUITE}" >&2
        echo >&2
        echo "${HELP}" >&2
        exit 1
esac

exit $SUITE_EXIT_CODE
