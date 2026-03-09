# Short Follow-up Mail to Dennis

Hi Dennis,

Quick follow-up on the `2.096.0 -> 2.096.1` spike window.

I checked:
- changelog `2.096.0`: <https://dlang.org/changelog/2.096.0.html>
- changelog `2.096.1`: <https://dlang.org/changelog/2.096.1.html>
- release compare: <https://github.com/dlang/dmd/compare/v2.096.0...v2.096.1.patch>

On the current rerun, that step is `+6.780%` on the compatible track, so smaller than the earlier number from my first mail, but still the best window to investigate first.

The compiler-side candidates that look most relevant for a semantic/CTFE-heavy benchmark are:
- `75fe50f497dceeaf49651259df8c52d3318f037e` — CTFE-related fix for issue 21687
- `9a7e7a0871dfe37ef936f1f145a58d2a6e6d8aea` — `ctfe_math` regression fix
- `dfa37aa33795ad33d9d69a2c3de02ddb4e586158` — CTFE destructor fix
- `655278312e2851b74b1f88dd71c7ffdb47224c20` — constructor flow-analysis fix
- `5bba6357deac1ba8d5994ffeb5c526716e89a274` — overload-resolution fix

So at this point I can narrow it to that release window and a small candidate commit set, but I cannot honestly call out a single causal commit yet without a real source-level bisect on the same benchmark/setup.

Best,
Sourav
