# Tidey Licensing Notes

## Scope

This note records the current licensing position for **Tidey**, assuming:

- Tidey is developed as a direct fork of iTerm2
- Tidey does **not** copy code from the current `cmux` / `agent-ide` codebase
- Tidey remains an open-source project

This is an engineering note, not legal advice.

## Current Inputs

### iTerm2

The iTerm2 repository currently says:

- `COPYING`: iTerm2 is licensed under **GPL v2 or later**
- `README.md`: iTerm2 is distributed under **GPLv3**

These statements are not actually in conflict. The practical reading is:

- iTerm2 code is available under **GPL v2 or later**
- because the project includes **Apache 2.0** dependencies, the effective combined distribution is **GPLv3 in practice**

For Tidey, the safest working assumption is:

> Treat the project as **GPLv3-governed** unless a narrower file-level analysis is needed later.

### cmux / agent-ide

The current `agent-ide` repository is licensed under **AGPLv3**.

That matters only if Tidey copies code from it.

If Tidey is a fresh product fork based on iTerm2 and only reuses:

- ideas
- workflow direction
- product concepts
- UI inspiration

then `agent-ide`'s AGPL license does **not** automatically attach to Tidey.

## Practical Consequences for Tidey

If Tidey ships as an iTerm2-derived open-source app under the effective GPLv3 path:

1. Any distributed Tidey binary must have corresponding source available.
2. Modifications to the iTerm2-derived codebase must remain under GPL-compatible terms.
3. Downstream forks of Tidey can modify and redistribute it, but must preserve GPL obligations.
4. Proprietary relicensing later would be difficult unless the project keeps very strict ownership control.

For the current stated goal, this is acceptable:

- open-source only
- no immediate commercial plan
- willingness to build on a copyleft base

## Recommended License Position

For Milestone 0, the cleanest working position is:

- Tidey is a fork of iTerm2
- Tidey should be treated as a **GPLv3** project in practice
- Tidey should avoid copying code from the AGPLv3 `agent-ide` repo unless the team explicitly wants to carry AGPL-style obligations into the new project

## What To Avoid

Avoid these until licensing is reviewed more carefully:

- copying source files from `agent-ide` into Tidey
- mixing code from projects with incompatible licenses
- assuming "open source" automatically means "license-safe to combine"

## Recommended Next Licensing Checks

Before Tidey is published publicly:

1. Review `LICENSE`, `COPYING`, and `README.license` in the iTerm2 fork together.
2. Review third-party notices under `ThirdParty/`.
3. Decide what license notice Tidey will present at the repo root and in-app.
4. If any `agent-ide` code is later ported over, re-check the GPLv3/AGPLv3 consequences at that time.

## Bottom Line

For the current plan, licensing is not a blocker.

The clean path is:

- build Tidey as a fresh iTerm2-based fork
- keep Tidey open source
- avoid code reuse from `agent-ide` unless there is a deliberate licensing decision to do so
