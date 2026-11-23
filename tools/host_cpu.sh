# shellcheck shell=sh
# Sourced by the checks that build programs for this machine's CPU, as `zig build` does when it
# names no CPU (docs/benchmarks.md, the limits of the full stack).

# The first 12 hexadecimal digits of the SHA-256 of the CPU's flags in /proc/cpuinfo. A build for
# this CPU lives in a directory named for them: CI keeps build directories across runners, and a
# build from a CPU with other flags stops on an instruction this one lacks (SIGILL, CI run 62).
host_features() {
    sed -n -e 's/^flags[[:space:]]*: //p' -e 's/^Features[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null |
        head -n 1 | sha256sum | cut -c1-12
}

# The environment that builds Go for the highest level of this CPU that Go names: GOAMD64=v1 to
# v4 on x86-64, from the flags /proc/cpuinfo lists, and GOARM64=v8.0 or v8.1, with `,crypto` when
# the CPU has the AES instructions, on arm64. It prints nothing elsewhere.
go_level() {
    flags="$(grep -m 1 -E '^(flags|Features)' /proc/cpuinfo 2>/dev/null | cut -d: -f2)"
    has() { for flag in "$@"; do case " ${flags} " in *" ${flag} "*) ;; *) return 1 ;; esac; done; }
    case "$(uname -m)" in
        x86_64)
            level=v1
            has cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 && level=v2
            [ "${level}" = v2 ] && has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave && level=v3
            [ "${level}" = v3 ] && has avx512f avx512bw avx512cd avx512dq avx512vl && level=v4
            echo "GOAMD64=${level}" ;;
        aarch64)
            level=v8.0
            has atomics && level=v8.1
            has aes pmull && level="${level},crypto"
            echo "GOARM64=${level}" ;;
    esac
}

# The flags that build Rust for this CPU.
# shellcheck disable=SC2034 # the scripts that source this file read it
rust_native="-C target-cpu=native"
