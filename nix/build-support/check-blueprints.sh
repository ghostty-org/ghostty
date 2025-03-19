#!/usr/bin/env bash

set -o nounset -o pipefail -o errexit

find src -name \*.blp -exec blueprint-compiler format {} \+
find src -name \*.blp -exec blueprint-compiler compile --output=/dev/null {} \;
