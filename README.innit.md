# Innit

Innit is a DS_GSI-oriented fork of Android 12 `system/core/init`.

Project spirit:

    reject thing that isn't it

Innit keeps Android second-stage init as PID 1, but adds a policy gatekeeper
so recovery-style init does not blindly trust imported rc files, service
definitions, event triggers, exec commands, or reboot-on-failure behavior.

## Baseline

This branch is based on:

    AOSP platform/system/core
    tag: android-12.0.0_r8

The published GitHub history is filtered to the `init/` subtree so the history
relevant to Android init is preserved while unrelated `system/core` components
are omitted.

## Primary target

    init_second_stage.recovery

## Design

- Android 12 recovery init baseline
- dynamic `libtinyxml2.so`
- recovery path excludes static `libxml2`
- no APEX dependency
- no normal Android framework bring-up assumption
- default-deny policy model for imported rc files, service definitions, event
  triggers, exec paths, selected builtin commands, and reboot-on-failure behavior

## Runtime policy path

Innit looks for:

    /system/etc/init/hw/innit.xml

If the file is absent, recovery init behaves like stock Android recovery init.
If the file is present but malformed, init halts rather than continuing in an
uncontrolled policy state.

## Runtime library requirement

Because Innit uses dynamic tinyxml2, the recovery-derived `/system` payload must
carry:

    /system/lib64/libtinyxml2.so

For the current recovery payload, `libtinyxml2.so` depends on:

    liblog.so
    libc++.so
    libc.so
    libm.so
    libdl.so

These are expected to already exist in the recovery-derived `/system/lib64`.

## Repository scope

This repository intentionally carries only the `init/` subtree needed for the
Innit project. Full AOSP `platform/system/core` contains many unrelated
components and large test fixtures that are not needed for Innit.

Canonical upstream remains:

    https://android.googlesource.com/platform/system/core
