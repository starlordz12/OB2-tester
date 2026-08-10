# OB2 Tester

OB2 Tester is an external, visible-window playtesting agent for the Windows beta of Orbit or Bust 2. It launches or attaches to the real Godot executable, reads the rendered HUD with local Windows OCR, and sends physical keyboard and mouse input only after verifying the target window.

The flight loop uses no model, API, cloud service, or network request. It learns from machine-readable run results, stops doomed or noncompetitive attempts early, and can compare all three orbit-capable presets.

## Verified benchmark

The fastest verified live result for build SHA-256 `94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42` is the Strap-On Orbiter at 215.7 mission-seconds, with Ap 134.13 km, Pe 72.02 km, and 3.47 t of fuel remaining.

- [Playtest report](docs/playtests/2026-08-09.md)
- [Reusable visible-game tester brief](docs/reusable-visible-game-tester.md)
- [Stable-orbit HUD evidence](benchmarks/94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42/evidence/srb/019_stable_orbit.png)
- [Closed-orbit map evidence](benchmarks/94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42/evidence/srb/020_stable_orbit_map.png)
- [Immutable benchmark state](benchmarks/94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42/best-known.json)

## Requirements

- Windows 10 or 11 with an interactive, unlocked desktop
- Windows PowerShell 5.1 and .NET Framework
- `Windows.Media.Ocr` with an English OCR language pack
- A visible, unobscured 1280x720 game client
- The tester and game running at the same Windows integrity level
- An authorized copy of `OrbitOrBust2.exe`; the game and its assets are not included

PowerShell 7 is not currently validated. The script is unsigned, so the examples use a process-scoped execution-policy bypass.

## Run

If this repo and `orbit-or-bust-2` are sibling folders, the executable is discovered automatically. Otherwise pass `-GameExe` or set `OB2_GAME_EXE`.

```powershell
# Compare every supported craft, one attempt per craft.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 `
  -Mode Run -Preset All -MaxAttempts 1

# Test only the verified SRB profile, allowing up to three learning attempts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 `
  -Mode Run -Preset SRB -MaxAttempts 3

# Use an explicit build path.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 `
  -Mode Run -Preset SRB -GameExe 'D:\Games\OrbitOrBust2.exe'
```

The default SHA guard intentionally refuses an unknown build. To test a new build, explicitly pass `-AllowUnknownBuild`, review the changed UI and telemetry, and create a new build-keyed benchmark before trusting a profile on that build.

## Offline validation

These checks do not open or control the game:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 -Mode Validate

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repository.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 `
  -Mode Probe `
  -ProbeImage .\benchmarks\94CA7490BB67F23E34BEB87B8C73E7D85D6C767A259BC2A90C57C39F0BB0EC42\evidence\srb\019_stable_orbit.png `
  -OutputRoot "$env:TEMP\OB2TesterProbe"
```

## What the controller does

- Verifies executable path and SHA-256 before input
- Refuses ambiguous duplicate game windows
- Verifies foreground window, process ID, and executable path before every input event
- Captures only the game client, not the title bar or surrounding desktop
- Validates craft name, part count, and stage count before launch
- Uses HUD/F3 cross-checks and rejects implausible OCR frames
- Stages from rendered action plus fuel/thrust state, never a blind timer
- Requires sane Ap/Pe readings and the rendered ORBIT confirmation for success
- Cuts thrust and reverts on stale telemetry, divergence, overshoot, suborbital descent, empty fuel, noncompetitive coast, or time-limit failure
- Releases injected keys in a `finally` block and attempts a safe cut/revert after controller exceptions

## Data and repository layout

- `Run-LiveOrbitTester.ps1` - controller, OCR parser, guidance, input, and learning loop
- `benchmarks/<exe-sha>/` - immutable verified result and curated evidence
- `docs/` - architecture, safety notes, CLI reference, and the manual playtest report
- `schemas/` - result and learning-state JSON schemas
- `tests/` - offline syntax, dependency, replay, privacy, and evidence-integrity checks
- `runs/` - generated evidence and transcripts; ignored by Git
- `%LOCALAPPDATA%\OB2Tester\state\<exe-sha>\learning-state.json` - mutable build-isolated learning state

The original game repository is not a dependency checkout for this project and was not modified to create it. Old headless/simulation-derived and fixed-schedule QA runners are deliberately excluded because they do not satisfy the visible, feedback-driven tester requirement.

## Safety

This tool controls the real mouse and keyboard. Keep the game visible and do not use the machine for unrelated work during a live run. Read [Safety and privacy](docs/safety-and-privacy.md) before operating it.

The prose playtest report is a reviewed artifact; the controller does not automatically write subjective game reviews.
