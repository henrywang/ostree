# The default entrypoint to working on this project.
# Run `just --list` to see available targets organized by group.
#
# By default the layering is:
# Github Actions -> Justfile -> podman -> build/test
# --------------------------------------------------------------------

# Detect the os for a workaround below
osid := `. /usr/lib/os-release && echo $ID`

stream := env('STREAM', 'stream9')
build_args := "--jobs=4 --build-arg=base=quay.io/centos-bootc/centos-bootc:"+stream

# ============================================================================
# Core workflows - the main targets most developers will use
# ============================================================================

# Build the container image from current sources
[group('core')]
build *ARGS:
    podman build {{build_args}} -t localhost/ostree {{ARGS}} .

[group('core')]
build-unittest *ARGS:
    podman build {{build_args}} --target build -t localhost/ostree-buildroot {{ARGS}} .

# Do a build but don't regenerate the initramfs
[group('core')]
build-noinitramfs *ARGS:
    podman build {{build_args}} --target rootfs -t localhost/ostree {{ARGS}} .

[group('core')]
unitcontainer-build *ARGS:
    podman build {{build_args}} --target bin-and-test -t localhost/ostree-bintest {{ARGS}} .

# We need a filesystem that supports O_TMPFILE right now (i.e. not overlayfs)
# or ostree hard crashes in the http code =/
unittest_args := "--pids-limit=-1 --tmpfs /run --tmpfs /var/tmp --tmpfs /tmp"

# Build and then run unit tests. If this fails, it will try to print
# the errors to stderr. However, the full unabridged test log can
# be found in target/unittest/test-suite.log.
[group('core')]
unittest *ARGS: build-unittest
    rm -rf target/unittest && mkdir -p target/unittest
    podman run --net=none {{unittest_args}} --security-opt=label=disable --rm \
        -v $(pwd)/target/unittest:/run/output --env=ARTIFACTS=/run/output \
        --env=OSTREE_TEST_SKIP=known-xfail-docker \
        localhost/ostree-buildroot  ./tests/makecheck.py {{ARGS}}

# For some reason doing the bind mount isn't working on at least the GHA Ubuntu 24.04 runner
# without --privileged. I think it may be apparmor?
unitpriv := if osid == "ubuntu" { "--privileged" } else { "" }

[group('core')]
unitcontainer: unitcontainer-build
    # need cap-add=all for mounting
    podman run --rm --net=none {{unitpriv}} {{unittest_args}} --cap-add=all --env=TEST_CONTAINER=1 localhost/ostree-bintest /tests/run.sh

# ============================================================================
# RPM build and TMT integration tests (uses Dockerfile.rpm)
# ============================================================================

# Build RPMs from current sources into target/packages/
[group('tmt')]
package:
    #!/bin/bash
    set -xeuo pipefail
    packages=target/packages
    if test -n "${OSTREE_SKIP_PACKAGE:-}"; then
        if test '!' -d "${packages}"; then
            echo "OSTREE_SKIP_PACKAGE is set, but missing ${packages}" 1>&2; exit 1
        fi
        exit 0
    fi
    podman build {{build_args}} -f Dockerfile.rpm --target rpmbuild -t localhost/ostree-rpmbuild .
    mkdir -p "${packages}"
    rm -vf "${packages}"/*.rpm
    podman run --rm localhost/ostree-rpmbuild tar -C /out/ -cf - . | tar -C "${packages}"/ -xvf -
    chmod a+rx target "${packages}"
    chmod a+r "${packages}"/*.rpm

# Build container image using RPMs (via Dockerfile.rpm)
[group('tmt')]
build-rpm *ARGS: package
    #!/bin/bash
    set -xeuo pipefail
    test -d target/packages
    pkg_path=$(realpath target/packages)
    podman build {{build_args}} -f Dockerfile.rpm --build-context "packages=${pkg_path}" -t localhost/ostree {{ARGS}} .

# Run tmt integration tests in VMs (builds RPM image first)
[group('tmt')]
test-tmt *ARGS: build-rpm
    @just test-tmt-nobuild {{ARGS}}

# Run tmt tests without rebuilding (for fast iteration)
[group('tmt')]
test-tmt-nobuild *ARGS:
    tmt run --all plan --name /tmt/plans/integration/plan-bootc-install {{ARGS}}

# ============================================================================
# Testing variants and utilities
# ============================================================================

# Start an interactive shell in the unittest container
[group('testing')]
unittest-shell: build-unittest
    podman run --rm -ti {{unittest_args}} "--env=PS1=unittests> " localhost/ostree-buildroot  bash

# For iterating on the tests
[group('testing')]
unitcontainer-fast:
    podman run --rm --net=none {{unitpriv}} {{unittest_args}} --cap-add=all --env=TEST_CONTAINER=1 -v $(pwd)/tests-unit-container:/tests:ro --security-opt=label=disable localhost/ostree-bintest /tests/run.sh

# ============================================================================
# Maintenance
# ============================================================================

# Run a build on the host system
[group('maintenance')]
build-host:
    . ci/libbuild.sh && build

# Run a build on the host system and "install" into target/inst
# This directory tree can then be copied elsewhere
[group('maintenance')]
build-host-inst: build-host
    make -C target/c install DESTDIR=$(pwd)/target/inst
    tar --sort=name --numeric-owner --owner=0 --group=0 -C target/inst -czf target/inst.tar.gz .

sourcefiles := "git ls-files '**.c' '**.cxx' '**.h' '**.hpp'"

# Reformat source files
[group('maintenance')]
clang-format:
    {{sourcefiles}} | xargs clang-format -i

# Check source files against clang-format defaults
[group('maintenance')]
clang-format-check:
    {{sourcefiles}} | xargs clang-format -i --Werror --dry-run
