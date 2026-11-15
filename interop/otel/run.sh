#!/bin/sh
# Runs the OpenTelemetry client of connect-zig's OTLP receiver (decision 40): it exports spans with
# OpenTelemetry's Go SDK, at the versions go.mod pins, then reads them back and compares each one
# (interop/README.md, "The OpenTelemetry client").
#
#   interop/otel/run.sh <base-url> <ca>
set -eu
cd "$(dirname "$0")"
export GOFLAGS=-mod=readonly
# The client, built once into a cache keyed by go.sum.
bin="${XDG_CACHE_HOME:-${HOME}/.cache}/connect-zig/interop-otel-$(sha256sum go.sum | cut -c1-12)"
mkdir -p "${bin}"
go build -o "${bin}/otel" .
"${bin}/otel" "$1" "$2"
