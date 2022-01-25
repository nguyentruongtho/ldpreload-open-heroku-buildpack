#!/bin/bash

set -o functrace
set -o errtrace # trap ERR in functions
set -o errexit
set -o nounset

lib="$PWD/path-mapping.so"
tempdir=/tmp/path-mapping
testdir="$tempdir"/tests

failure() {
  local lineno=$1
  local msg=$2
  echo "Failed at $lineno: $msg"
}
trap 'failure ${LINENO} "$BASH_COMMAND"' ERR

setup() {
    teardown
    mkdir -p "$testdir/real"; cd "$testdir/real"
    mkdir -p dir1/dir2
    echo content0 >file0
    echo content1 >dir1/file1
    echo content2 >dir1/dir2/file2
    echo content3 >dir1/dir2/file3
    cd "$testdir"
}
teardown() {
    cd "$tempdir"
    rm -rf "$testdir"
}

check_strace_file() {
    program_name="$1"
    strace_file="$tempdir/strace/$program_name"
    lines="$( grep virtual "$strace_file" | grep -vE '^execve|^write|^Mapped Path:' || true )"
    if [[ "$lines" ]] ; then
        echo "Unmapped path in $strace_file:"
        echo "$lines"
        return 1
    fi
}

check_output_file() {
    program_name="$1"
    expected="$2"
    out_file="$tempdir/out/$program_name"
    output="$(cat "$out_file")"
    if ! [[ "$output" == "$expected" ]]; then
        echo "ERROR: output was not as expected:"
        echo "'$output' != '$expected'"
        return 1
    fi
}

assert_readlink() {
    create_link_path="$1"
    link_content="$2"
    readlink_path="$3"
    expected="$4"
    ln -sf "$link_content" "$create_link_path"
    result="$(LD_PRELOAD="$lib" readlink -f "$readlink_path" 2>/dev/null)"
    if ! [[ "$result" == "$expected" ]]; then
        echo "assert_readlink $@:"
        echo "'$result' != '$expected'"
        return 1
    fi
}
test_readlink() {
    setup
    assert_readlink "$testdir/real/link" "$testdir/real/target" "$testdir/real/link" "$testdir/real/target" # no mapping
    assert_readlink "$testdir/real/link" "$testdir/real/target" "$testdir/virtual/link" "$testdir/real/target" # link name mapped
    assert_readlink "$testdir/real/link" "$testdir/virtual/target" "$testdir/virtual/link" "$testdir/virtual/target" # link contents not mapped
}

test_readlink_f() {
    setup
    ln -s "dir2/file2" "$testdir/real/dir1/relativelink"
    ln -s "$testdir/real/dir1/dir2/file2" "$testdir/real/dir1/reallink"
    LD_PRELOAD="$lib" ln -s "$testdir/virtual/dir1/dir2/file2" "$testdir/virtual/dir1/virtlink" 2>/dev/null
    LD_PRELOAD="$lib" strace readlink -f "$testdir/virtual/dir1/relativelink" >../out/readlink_f_relativelink 2>../strace/readlink_f_relativelink
    LD_PRELOAD="$lib" strace readlink -f "$testdir/virtual/dir1/reallink" >../out/readlink_f_reallink 2>../strace/readlink_f_reallink
    LD_PRELOAD="$lib" strace readlink -f "$testdir/virtual/dir1/virtlink" >../out/readlink_f_virtlink 2>../strace/readlink_f_virtlink
    check_strace_file readlink_f_relativelink
    check_strace_file readlink_f_reallink
    #check_strace_file readlink_f_virtlink # False positive because link contains the word "virtual"
    check_output_file readlink_f_relativelink "$testdir/virtual/dir1/dir2/file2"
    check_output_file readlink_f_reallink "$testdir/real/dir1/dir2/file2"
    check_output_file readlink_f_virtlink "$testdir/virtual/dir1/dir2/file2"
    test x"$(cat "$testdir/real/dir1/relativelink")"
}

test_ln() {
    setup
    LD_PRELOAD="$lib" strace ln -s "linkcontent" "$testdir/virtual/dir1/link" 2>../strace/ln
    readlink "$testdir/real/dir1/link" >../out/ln
    check_strace_file ln
    check_output_file ln "linkcontent"
}

disabled_test_thunar() { # Disabled because slow and not really useful
    if ! which Thunar >/dev/null; then
        echo "Thunar not found, skipping test case"
        return
    fi
    if pgrep Thunar; then
        echo "Thunar is running. Execute Thunar -q if you want to run it."
        return
    fi
    setup
    cd real
    LD_PRELOAD="$lib" strace Thunar "$testdir/virtual" >../out/Thunar 2>../strace/Thunar &
    sleep 3; kill %1
    check_strace_file Thunar
}

test_cat() {
    setup
    LD_PRELOAD="$lib" strace cat "$testdir/virtual/file0" >../out/cat 2>../strace/cat
    check_output_file cat "content0"
    check_strace_file cat
}

test_find() {
    setup
    LD_PRELOAD="$lib" strace find "$testdir/virtual" >../out/find 2>../strace/find
    check_strace_file find
    check_output_file find "/tmp/path-mapping/tests/virtual
/tmp/path-mapping/tests/virtual/file0
/tmp/path-mapping/tests/virtual/dir1
/tmp/path-mapping/tests/virtual/dir1/file1
/tmp/path-mapping/tests/virtual/dir1/dir2
/tmp/path-mapping/tests/virtual/dir1/dir2/file3
/tmp/path-mapping/tests/virtual/dir1/dir2/file2"
}

test_grep() {
    setup
    LD_PRELOAD="$lib" strace grep -R content "$testdir/virtual" >../out/grep 2>../strace/grep
    check_strace_file grep
    check_output_file grep "/tmp/path-mapping/tests/virtual/file0:content0
/tmp/path-mapping/tests/virtual/dir1/file1:content1
/tmp/path-mapping/tests/virtual/dir1/dir2/file3:content3
/tmp/path-mapping/tests/virtual/dir1/dir2/file2:content2"
}

test_chmod() {
    setup
    chmod 700 "$testdir/real/file0"
    LD_PRELOAD="$lib" strace chmod 777 "$testdir/virtual/file0" >../out/chmod 2>../strace/chmod
    check_strace_file chmod
    test "$(stat -c %a "$testdir/real/file0")" == 777
}

test_utime() {
    setup
    LD_PRELOAD="$lib" strace ../testtool-utime "$testdir/virtual/dir1/file1" 2>../strace/utime
    chmod 700 real/dir1/file1
    stat -c %X:%Y "real/dir1/file1" >../out/utime
    check_strace_file utime
    check_output_file utime '200000000:100000000'
}

test_rm() {
    setup
    LD_PRELOAD="$lib" strace rm -r "$testdir/virtual/dir1" >../out/rm 2>../strace/rm
    check_strace_file rm
    test '!' -e "$testdir/real/dir1"
}

test_rename() {
    setup
    LD_PRELOAD="$lib" strace /usr/bin/mv "$testdir/virtual/dir1" "$testdir/virtual/dir1_renamed" >../out/rename 2>../strace/rename
    check_strace_file rename
    test '!' -e "$testdir/real/dir1"
    test -e "$testdir/real/dir1_renamed"
}

test_bash_exec() {
    setup
    cp /usr/bin/echo "$testdir/real/dir1/"
    LD_PRELOAD="$lib" strace bash -c "'$testdir/virtual/dir1/echo' arg1 arg2 arg3 arg4 arg5" >../out/bash_exec 2>../strace/bash_exec
    check_strace_file bash_exec
    check_output_file bash_exec "arg1 arg2 arg3 arg4 arg5"
}

test_bash_cd() { # Test chdir()
    setup
    LD_PRELOAD="$lib" strace bash -c "ls; cd virtual; ls; cd dir1; ls" >../out/bash_cd 2>../strace/bash_cd
    check_strace_file bash_cd
    check_output_file bash_cd $'real\ndir1\nfile0\ndir2\nfile1'
}

test_execl() {
    setup
    cp ../testtool-execl ../testtool-printenv real/

    LD_PRELOAD="$lib" strace "$testdir/virtual/testtool-execl" execl "$testdir/virtual/testtool-printenv" 0 \
        >../out/execl0 2>../strace/execl0
    check_strace_file execl0
    check_output_file execl0 $'TEST0=value0'

    LD_PRELOAD="$lib" strace "$testdir/virtual/testtool-execl" execl "$testdir/virtual/testtool-printenv" 1 \
        >../out/execl1 2>../strace/execl1
    check_strace_file execl1
    check_output_file execl1 $'arg1\nTEST0=value0'

    LD_PRELOAD="$lib" strace "$testdir/virtual/testtool-execl" execlp "$testdir/virtual/testtool-printenv" 2 \
        >../out/execlp2 2>../strace/execlp2
    check_strace_file execlp2
    check_output_file execlp2 $'arg1\narg2\nTEST0=value0'

    LD_PRELOAD="$lib" strace "$testdir/virtual/testtool-execl" execle "$testdir/virtual/testtool-printenv" 3 \
        >../out/execle3 2>../strace/execle3
    check_strace_file execle3
    check_output_file execle3 $'arg1\narg2\narg3\nTEST1=value1\nTEST2=value2'

}

test_du() {
    setup
    LD_PRELOAD="$lib" strace du "$testdir/virtual/" >../out/du 2>../strace/du
    check_strace_file du
    check_output_file du "8	/tmp/path-mapping/tests/virtual/dir1/dir2
12	/tmp/path-mapping/tests/virtual/dir1
16	/tmp/path-mapping/tests/virtual/"
}

test_df() { # Tests realpath()
    setup
    expected="$(df -h "$testdir/real/")"  # in RAM, the available space can fluctuate by a few bytes. Hopefully the -h flag makes it robust enough to pass most of the time
    LD_PRELOAD="$lib" strace df -h "$testdir/virtual/" >../out/df 2>../strace/df
    check_strace_file df
    check_output_file df "$expected"
}

test_getfacl() { # Tests getxattr()
    setup
    expected="$(getfacl "$testdir/real/" 2>/dev/null | sed 's/real/virtual/')"  # in RAM, the available space can fluctuate by a few bytes. Hopefully the -h flag makes it robust enough to pass most of the time
    LD_PRELOAD="$lib" strace getfacl "$testdir/virtual/" >../out/getfacl 2>../strace/getfacl
    check_strace_file getfacl
    check_output_file getfacl "$expected"
}

# Setup up output directories for the test cases
mkdir -p "$tempdir/out"
mkdir -p "$tempdir/strace"

# Find all declared functions starting with "test_" in a random order
testcases="$(declare -F | cut -d " " -f 3- | grep '^test_' | shuf)"
num_testcases="$(echo "$testcases" | wc -l)"

N=0
if [[ $# -gt 0 ]]; then
    while [[ $# -gt 0 ]]; do
        if [[ "$testcases" =~ "$1" ]]; then
            echo "$1"
            $1
            shift
        else
            echo "Unknown test case $1"
            exit 1
            N=$[N+1]
        fi
    done
else
    # If no argument is given, execute all test cases
    for cmd in $testcases; do
        echo "$cmd"
        $cmd
        N=$[N+1]
    done
fi

echo "$N/$num_testcases TESTS PASSED!"
#rm -rf "$tempdir"
