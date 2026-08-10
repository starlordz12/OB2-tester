# Repository scope

This repository intentionally contains the complete current controller code, build-keyed benchmark data, the reviewed playtest report, schemas, offline checks, and a curated evidence set sufficient to reproduce the verified claims.

It intentionally excludes:

- `OrbitOrBust2.exe`, Godot export data, game source, DLLs, and assets;
- the obsolete fixed-schedule 30-minute runner, which was open-loop and did not restart intelligently;
- simulation/headless artifacts that did not play the visible executable;
- the earlier playtest report whose claimed orbit had a negative periapsis;
- 100+ redundant development screenshots and raw transcripts containing machine-specific paths;
- mutable runtime state and new run output.

The original artifact package remains local and untouched. The published evidence retains the successful SRB sequence plus bounded Heavy and Orbit-Class comparisons. `SHA256SUMS` binds every retained benchmark file.

