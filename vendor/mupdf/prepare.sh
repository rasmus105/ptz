#!/bin/sh
set -eu

destination=$2
cp -a "$1/." "$destination"
shift 2
for correction in "$@"; do
    patch --batch --forward -F 0 -d "$destination" -p1 < "$correction"
done
