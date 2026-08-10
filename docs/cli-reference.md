# CLI reference

Run with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Run-LiveOrbitTester.ps1 [parameters]
```

| Parameter | Default | Meaning |
|---|---|---|
| `-Mode` | `Validate` | `Validate` checks local prerequisites without input, `Run` controls the game, and `Probe` reads a live frame or replays `-ProbeImage` offline. |
| `-Preset` | `SRB` | `SRB`, `Heavy`, `Orbiter`, or `All`. `All` compares every supported craft. |
| `-MaxAttempts` | `1` | Maximum attempts per selected preset. |
| `-TurnStartM` | `350` | Altitude where the gravity turn begins. |
| `-TurnEndM` | `30000` | Altitude where the nominal target becomes horizontal. |
| `-TargetApM` | `82000` | Initial ascent apoapsis target in meters. |
| `-TargetPeM` | `71000` | Stable-orbit periapsis margin in meters. |
| `-MaxAoARad` | `0.28` | Maximum atmospheric angle-of-attack offset from prograde. |
| `-HardLimitS` | `235` | Per-attempt mission-time ceiling. |
| `-GameExe` | environment/sibling discovery | Exact path to `OrbitOrBust2.exe`. |
| `-ExpectedSha256` | verified beta SHA | Refuses a different build unless `-AllowUnknownBuild` is also present. |
| `-AllowUnknownBuild` | off | Explicitly permits an unrecognized executable while a new build adapter is being validated. |
| `-OutputRoot` | `./runs` | Generated transcript, result, and screenshot directory. |
| `-LearningStatePath` | `%LOCALAPPDATA%\OB2Tester\state\<exe-sha>\learning-state.json` | Mutable, build-isolated learning state. |
| `-BenchmarkStatePath` | verified benchmark JSON | Immutable seed benchmark used when compatible runtime state is absent. |
| `-ProbeImage` | empty | Image to replay in `Probe` mode without launching the game. |
| `-ProbeKey` | empty | Key to send before a live probe. Cannot be combined with offline replay. |
| `-ProbeHoldMs` | `500` | Hold duration for a live probe key. |

## Exit and failure behavior

Missing builds, SHA mismatches, ambiguous windows, failed focus validation, invalid geometry, and unreadable telemetry fail closed. If an exception occurs during powered flight, the outer safety handler attempts throttle cut and revert before returning the error.

The script prints `RESULT_DIR=<relative path>` after a completed run. Inspect `session-results.json` and the transcript before accepting a benchmark.
