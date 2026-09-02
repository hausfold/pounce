#!/bin/bash
# pounce: name = Report Pounce Issue
# pounce: description = Open a pre-filled bug report on GitHub
# pounce: icon = ladybug
# pounce: network = true

# One line, because the work is `pounce report`'s (Entry.swift, ReportMode) and
# it belongs there: the block it prefills is pounce's own doctor report plus the
# version, macOS and install cohort, none of which a shell script can assemble
# without re-deriving all of it.
#
# ⚠️ What this file used to be is worth knowing, because it is the mistake the
# whole door exists to avoid. It hand-built `issues/new?labels=bug&title=&body=`
# with a markdown skeleton in the query, and its own comment said "no hosted
# .github/ISSUE_TEMPLATE needed". That was true when it was written and stopped
# being true when the forms landed: a `body=` prefill opens GitHub's BLANK
# editor and walks straight past bug.yml — its fields, its "wrong repo? file it
# anyway" preamble, and the `bug`/`triage` labels it applies. Nothing failed.
# Every report filed through this row for a year simply arrived shapeless.
#
# The form is the ONLY feedback channel pounce has (there is no telemetry in
# anything we ship), so the row that opens it has to open the real one.

exec pounce report
