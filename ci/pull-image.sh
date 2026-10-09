#!/bin/sh
# Make a Docker Hub image available to `docker run` without depending on an
# anonymous pull succeeding on the day:
#
#   sh ci/pull-image.sh <image> <tarball>
#
# The workflows restore TARBALL from the actions cache first (keyed by image
# and month, so the image is refreshed once a month). With it there, the image
# is loaded and nothing is pulled. Without it, the image is pulled, retried
# with backoff when Docker Hub answers with its anonymous rate limit (the
# runners share addresses, so the limit is often spent before the job starts),
# and saved to TARBALL for the cache step that follows.
set -eu

image=${1:?usage: pull-image.sh <image> <tarball>}
tar=${2:?usage: pull-image.sh <image> <tarball>}

if [ -f "$tar" ]; then
  docker load -i "$tar"
  exit 0
fi

delay=30
for attempt in 1 2 3 4 5; do
  if docker pull "$image"; then
    mkdir -p "$(dirname "$tar")"
    docker save -o "$tar" "$image"
    exit 0
  fi
  [ "$attempt" = 5 ] && break
  echo "pull-image: pull of $image failed (attempt $attempt), retrying in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2))
done
echo "pull-image: could not pull $image" >&2
exit 1
