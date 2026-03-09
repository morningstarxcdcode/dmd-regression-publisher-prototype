# Draft Reply to Dennis

Hi Dennis,

Thanks, good point.

I updated the notes so the methodology is explicit.

For this chart:
- "compile time" = wall-clock time to compile the same synthetic template/CTFE-heavy file, `benchmark.d`
- command used for the release sweep: `dmd benchmark.d -O -c -of=<temp>.o`
- so it is compile-only timing, not link time
- run policy: `2` warmups + `7` measured runs per release, plotted as the median of the measured runs
- machine: MacBook Air (`Apple M4`, `macOS arm64`)
- the nightly build was only used separately for `-ftime-trace`, not for the historical release sweep

You're right that the original chart/report should have said that directly.

For the spike attribution, I started from the `2.096.0 -> 2.096.1` window.

- current rerun in the repo shows `+6.780%` for that step on the compatible track
- the official changelog and release-window commit list narrow it to a small compiler/CTFE-heavy candidate set
- I am treating the earlier larger number from my email as something to reconcile against the rerun before calling it a confirmed regression

Best,
Sourav
