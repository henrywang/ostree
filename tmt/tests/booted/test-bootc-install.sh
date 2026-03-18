#!/bin/bash
# Test: Build ostree container image and run bootc install to-filesystem
# Verifies that the custom-built ostree integrates correctly with bootc.
set -xeuo pipefail

image=localhost/ostree:latest

# If the image isn't already available (e.g. Packit environment),
# build it from source
if ! podman image exists "${image}"; then
    echo "Image ${image} not found, building from source..."
    cd /var/tmp/ostree-source
    podman build --jobs=4 -t "${image}" .
fi

# Run bootc install to-filesystem
podman run \
    --env BOOTC_SKIP_SELINUX_HOST_CHECK=1 \
    --rm -ti --privileged \
    -v /:/target --pid=host --security-opt label=disable \
    -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
    "${image}" \
    bootc install to-filesystem --skip-fetch-check --replace=alongside /target

# Verify SELinux labeling for /etc
echo "Verifying SELinux labels on /etc..."
ls -dZ /ostree/deploy/default/deploy/*.0/etc | grep :etc_t:
echo "SELinux label verification passed."
