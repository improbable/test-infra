#!/bin/bash
# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

CACHE_ROOT="${CACHE_ROOT:-storage.googleapis.com/io-internal-infra-bazel-remote-cache-production}"

# get the installed version of a debian package
package_to_version () {
    dpkg-query --showformat='${Version}' --show "$1"
}

# look up a binary with `command -v $1` and return the debian package it belongs to
command_to_package () {
    # NOTE: we resolve symlinks first because debian packages can provide alternatives
    # by `update-alternatives` in postinit scripts, which updates a common
    # symlink for a provided file to the backing entry.
    # https://wiki.debian.org/DebianAlternatives
    local binary_path
    binary_path=$(readlink -f "$(command -v "$1")")
    # `dpkg-query --search $file-pattern` outputs lines with the format: "$package: $file-path"
    # where $file-path belongs to $package
    # https://manpages.debian.org/jessie/dpkg/dpkg-query.1.en.html
    dpkg-query --search "${binary_path}" | cut -d':' -f1
}

# get the installed package version relating to a binary
command_to_version () {
    local package
    package=$(command_to_package "$1")
    package_to_version "${package}"
}

hash_toolchains () {
    # if $CC is set bazel will use this to detect c/c++ toolchains, otherwise gcc
    # https://blog.bazel.build/2016/03/31/autoconfiguration.html
    local cc="${CC:-gcc}"
    local cc_version
    cc_version=$(command_to_version "$cc")
    # NOTE: IIRC some rules call python internally, this can't hurt
    local python_version
    python_version=$(command_to_version python)
    # the rpm packaging rules use rpmbuild
    local rpmbuild_version
    rpmbuild_version=$(command_to_version rpmbuild)
    # combine all tool versions into a hash
    # NOTE: if we change the set of tools considered we should
    # consider prepending the hash with a """schema version""" for completeness
    local tool_versions
    tool_versions="CC:${cc_version},PY:${python_version},RPM:${rpmbuild_version}"
    echo "${tool_versions}" | md5sum | cut -d" " -f1
}

make_bazel_rc () {
    local cache_id
    cache_id="k8s-test-infra,$(hash_toolchains)"
    local cache_url
    cache_url="https://${CACHE_ROOT}/${cache_id}"
    echo "build:imp-ci --remote_http_cache=${cache_url}"
}

# https://docs.bazel.build/versions/master/user-manual.html#bazelrc
# bazel will look for two RC files, taking the first option in each set of paths
# firstly:
# - The path specified by the --bazelrc=file startup option. If specified, this option must appear before the command name (e.g. build)
# - A file named .bazelrc in your base workspace directory
# - A file named .bazelrc in your home directory
bazel_rc_contents=$(make_bazel_rc)
echo "create_bazel_cache_rcs.sh: Configuring '${HOME}/.bazelrc' and '/etc/bazel.bazelrc' with"
echo "# ------------------------------------------------------------------------------"
echo "${bazel_rc_contents}"
echo "# ------------------------------------------------------------------------------"
echo "${bazel_rc_contents}" >> "${HOME}/.bazelrc"
# Aside from the optional configuration file described above, Bazel also looks for a master rc file next to the binary, in the workspace at tools/bazel.rc or system-wide at /etc/bazel.bazelrc.
# These files are here to support installation-wide options or options shared between users. Reading of this file can be disabled using the --nomaster_bazelrc option.
echo "${bazel_rc_contents}" >> "/etc/bazel.bazelrc"
# hopefully no repos create *both* of these ...
