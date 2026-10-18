#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
xcrun swift-format lint --strict --recursive Sources Tests Package.swift Scripts/verify-update.swift
for TASK_SCRIPT in Scripts/*.sh; do
    bash -n "$TASK_SCRIPT"
done
