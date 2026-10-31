# Contributing

This repo documents a working pattern (policy routing + a SOCKS5-aware
gateway + a fail-closed kill switch), built and verified against one real
stack (MikroTik + VirtualBox + a residential/ISP SOCKS5 proxy). Contributions
that extend it to other hardware/software, or that harden what's here, are
welcome.

## How this repo is organized (read this before editing)

- **`docs/`** — generic and reproducible. No real IPs, hostnames, or
  credentials, ever. Where a concrete example helps, use the repo's
  existing example addressing (`172.16.50.0/24`, VM IP `172.16.50.237` —
  see `docs/ARCHITECTURE.md`'s "Example addressing" table) rather than
  inventing a new one, so examples stay consistent across files.
- **`configs/`** — templates and generic scripts, named `*.template` or
  `*.example` when they need deployment-specific values filled in. These
  are meant to be copied and filled in, not run as-is.
- **`local/`** — real, deployment-specific values. This directory is
  git-ignored (see `.gitignore`) and should **never** appear in a commit.
  If you're testing changes against a real deployment, your own real
  values belong here, not in `docs/` or `configs/`.
- **`AGENTS.md`/`CLAUDE.md`** — context for AI coding agents. Keep these
  generic for the same reason as `docs/` — they describe the pattern and
  known gotchas, not one deployment's actual IPs/credentials.

## Before opening a PR

1. **Grep your diff for secrets before committing** — this project's own
   build process did this every time (see the pattern throughout
   `docs/` and the convention it follows). A real IP, hostname, or
   credential leaking into a committed file is the one mistake that
   matters most here.
2. **Prefer verified claims over plausible ones.** Most of this repo's
   documentation exists because something was actually tested on real
   hardware and the result (including surprising or inconvenient results)
   was written down — not because it seemed like it should work. If you're
   documenting new behavior, test it for real first.
3. **Keep the terse, evidence-based style.** Say what happened, why it
   matters, and how to reproduce/verify it. Skip filler. Comments in
   scripts/configs should explain *why*, not restate what the line
   obviously does.
4. **Update cross-references.** If you change something `AGENTS.md`,
   `docs/OPERATIONS.md`, or `docs/TROUBLESHOOTING.md` already describes,
   update those too rather than leaving them stale — a future reader
   (human or agent) trusts them as current.

## Contributing a new hardware/software variant

Adapting this to a different router, hypervisor, or proxy/tunnel type?
See [docs/USE-CASES.md](docs/USE-CASES.md) for the variants already
sketched out. To contribute one:

1. Add or extend a section in `docs/USE-CASES.md` describing the
   variation and what actually differs from the documented default.
2. If it needs new config, add a generic template under `configs/`
   following the existing `*.template`/`*.example` naming.
3. Note any new failure modes in `docs/OPERATIONS.md` if the variant
   changes how the kill switch or failure behavior works — this matters
   more than it sounds; see how different "VM unreachable" vs. "ISP
   glitch" behave in the existing writeup for the level of detail that's
   useful.

## Reporting issues

Open an issue with: what you were trying to do, what hardware/software
versions are involved, and what actually happened (exact error text,
relevant log lines) — not just "it doesn't work." If it's
security-relevant (e.g. a leak vector this repo's docs don't already
cover), say so in the title.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
