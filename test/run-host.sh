#!/usr/bin/env bash
#
# This runs a single test case from the host (not from Docker itself). The
# arguments are the same as run.sh but this wraps it in docker.

DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
IMAGE=$(docker build --file ${DIR}/Dockerfile -q ${DIR})

docker run \
  --init \
  --rm \
  -v ${DIR}:/src \
  --entrypoint "xvfb-run" \
  $IMAGE \
  --server-args="-screen 0, 1600x900x24" \
  /entrypoint.sh "$@"
