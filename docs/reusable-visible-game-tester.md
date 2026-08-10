# Skill Optimization Report

## 1. Original Project Summary

The real goal was to build a low-usage tester that plays a visible Windows game build, learns from outcomes, abandons doomed attempts quickly, compares modules fairly, and produces an evidence-backed design review. This is a software automation, game-testing, and safety-critical desktop-input project; the general design-brief and software-deliverables checklists apply.

## 2. What Worked Well

- The executable itself, rather than a simulation substitute, became the source of truth.
- Local Windows OCR eliminated model, API, and network usage from the control loop.
- Explicit orbit criteria made a negative periapsis impossible to mislabel as success.
- Screenshots, action transcripts, JSON results, executable hashes, and a manual report make claims auditable.
- The game repository remained outside the tester repository and was not modified.

## 3. What Was Missing At First

- “Play the real visible executable” and “do not touch the game repository” were added after the initial request.
- Fast failure recognition and immediate restart were initially less explicit than the overall fastest-orbit goal.
- The publication target, privacy level, evidence-retention boundary, and repository contents were added late.
- Foreground verification, click-position validation, build identity, duplicate-window rejection, and controller locking needed an explicit safety pass.
- Stable JSON shapes, build-isolated learning state, and same-session best-time promotion needed an explicit machine-readable acceptance pass.

## 4. Why Those Missing Items Mattered

Without a visible-build requirement, an offline simulator could appear successful while failing to prove that the exported game was played. Without early-abort rules, a controller can spend minutes completing a trajectory already known to be suborbital. Without an input safety boundary, global keyboard or mouse events can reach another application. Without build and evidence identity, results from different binaries can be mixed. Without a Git allowlist, ignored development captures can leak through an ad-hoc directory archive.

## 5. Reusable Lessons Learned

1. Define the observable real system and prohibit substitutes when they do not satisfy acceptance.
2. Express success and failure as measurable gates before writing the control policy.
3. Treat desktop input as a safety-critical actuator: identify, focus, revalidate, position-check, then act.
4. Put a cheap deterministic observer in the tight loop and reserve model usage for planning or reporting.
5. Bind every benchmark and learning record to an immutable build identity.
6. Promote useful results immediately so learning constrains later work in the same session.
7. Publish from the Git index, not from a working directory that may contain ignored private artifacts.

## 6. Better Default Template Sections

A future visible-game tester brief should state, in this order:

- exact executable/build and whether source access is permitted;
- platform, window geometry, controls, and observation method;
- measurable success gate and comparison metric;
- early-abort and restart conditions;
- input safety and cleanup behavior;
- learning-state schema and build-isolation rule;
- evidence retention, privacy, and repository visibility;
- deliverable layout, validation commands, and definition of done.

## 7. Recommended Questions Before Starting Similar Projects

- What exact binary, version, resolution, and input bindings are authoritative?
- Must play remain visible, and may the tester inspect source or only rendered output?
- What numeric state proves success, and how many independent observations confirm it?
- Which conditions prove an attempt cannot win or cannot beat the saved best?
- Which actions are safe for automatic restart, and what cleanup is mandatory after failure?
- Which modules must be compared, under what attempt/time budget?
- What evidence may be retained or published, and must the repository be private?

Do not forget build hashing, focus races, cursor validation, stale telemetry, duplicate processes, locked/RDP desktops, key release, data retention, stable JSON schemas, and an honest distinction between live evidence and offline priors.

## 8. Risk Checklist

Reduced risks include wrong-window input, off-client clicks, stale or contradictory telemetry, false orbit claims, cross-build learning, endless failed runs, accidental game-binary commits, and personal-path leakage in tracked text.

Remaining risks are UI/theme drift, OCR errors not represented by current evidence, custom key bindings, minimized or obscured windows, other software moving the pointer between validation and input, unvalidated PowerShell 7 behavior, and historical evidence that is appropriate only for this private repository. Every new game build still needs an adapter and live revalidation.

## 9. Optimized Final Prompt

> Build a standalone, private Windows repository for a feedback-driven tester of the exact supplied game executable. Do not modify the game repository or bundle its binary/assets. The tester must control the visible real build, observe rendered state with a local zero-network method, and fail closed before every global input event.
>
> Define a numeric success gate, validate it across distinct frames, compare the named modules, and minimize mission time. Abort and restart as soon as telemetry proves the attempt is doomed or cannot beat the best verified result. Persist only finite, validated, build-hash-matched learning and apply a new best immediately within the current session.
>
> Deliver the controller, build adapter/reference data, README, architecture and safety docs, JSON schemas, offline tests, a curated evidence set, and an evidence-backed playtest report. Keep raw runs and binaries ignored. Publish only the reviewed Git index to a private repository. Done means offline validation passes, the repository contains no game binary or secrets, the original repository is unchanged, and live success claims are tied to visible-build evidence.

## 10. Future Skill Improvements

- Extract UI coordinates, telemetry patterns, physics, controls, and policies into SHA-keyed adapter files.
- Add replay fixtures for failed OCR, focus loss, cursor movement, stale frames, and schema compatibility.
- Add configurable evidence levels and retention limits.
- Add a client-capture backend that remains private even when windows overlap.
- Generate a draft factual run summary from JSON while keeping subjective game critique human/model reviewed.
- Validate new adapters through a safe calibration mode before enabling input.

## 11. Saveable Skill Definition

```yaml
name: visible-game-playtester
description: Build or run a low-usage, feedback-driven tester against a real visible Windows game executable, with local observation, fail-closed input, early restart, build-isolated learning, evidence, and a playtest report.
workflow:
  - identify the exact build, controls, client geometry, and allowed source access
  - define success, failure, comparison, privacy, and no-touch boundaries
  - calibrate local rendered-state observation without live input
  - implement target-verified input and exception cleanup
  - run bounded attempts and promote validated learning immediately
  - retain build-bound evidence and separate live proof from offline priors
  - validate schemas, privacy, repository scope, and documentation
acceptance:
  - no model or network calls in the control loop
  - no input without exact foreground-process and pointer checks
  - no success without multi-frame rendered-state confirmation
  - no cross-build learning reuse
  - no modification of the tested game's repository
  - only reviewed, private-safe files enter the publication index
```
