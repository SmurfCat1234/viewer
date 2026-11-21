# Reproducing overlapping AIS item reads

This harness runs the single-item dispatch and fetch code extracted from both viewer source trees with simulated inventory state, coroutine queue, and transport. It needs no Second Life account or grid.

| Viewer | Upstream | Candidate |
| --- | --- | --- |
| Second Life Viewer | `33c60244` | `2b08961a` |
| Firestorm | `ce00dfd2` | `b710d57c` |

The test gives three interleaved callers the same six unknown items and holds all completions until the wave has been submitted. It repeats for 200 waves with fresh IDs. This deliberately exercises overlap, and the counts do not estimate live-grid login times.

## Run

Use PowerShell 7, Git, and a C++17 compiler with the clang++ command-line interface. Run in a directory containing the two checkouts, with the harness downloaded into that directory or available by path.

```powershell
git clone --branch fix/ais-coalesce-item-fetches --depth 2 https://github.com/SmurfCat1234/viewer.git secondlife-viewer
git clone --branch fix/ais-coalesce-item-fetches --depth 2 https://github.com/SmurfCat1234/phoenix-firestorm.git firestorm-viewer
pwsh -File ./run-comparison.ps1 -RepoRoot . -Compiler clang++ -OutputDirectory ./results -AISOnly
```

The patched test still checks that forced refresh works, a missing capability does not leak a fetch slot, and subsequent demand can retry after a failed request. Both viewer pairs produced 3,600 → 1,200 submissions and 18 → 6 peak occupied slots, with all 1,200 distinct items accepted on both sides. The CSV also includes unchanged observer-log control columns.

[Second Life Viewer draft](https://github.com/secondlife/viewer/pull/6757) · [Firestorm draft](https://github.com/FirestormViewer/phoenix-firestorm/pull/332)

## Release source cross-check

The same offline workload submitted 3,600 GETs and occupied 18 slots at peak on each release source. Both received all 1,200 distinct items. This check used the release source functions and simulated transport.

- Second Life Viewer `26.5.0.42122621216`, tag `Second_Life_Release#c74c2c9b-26.5`, commit `c74c2c9b`.
- Firestorm `7.2.5.81788`, tag `Firestorm_Release_7.2.5.81788`, commit `4ac201fd`.

In checkouts with these tags fetched, pass `-UpstreamOnly -AISOnly -SecondLifeBaseline 'Second_Life_Release#c74c2c9b-26.5' -FirestormBaseline 'Firestorm_Release_7.2.5.81788'` to repeat the release source check.
