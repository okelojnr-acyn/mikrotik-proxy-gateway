## What changed and why

## Tested how

(This repo's own convention: claims backed by something actually run on
real hardware/VMs, not just "should work." Say what you ran and what you
saw.)

## Checklist

- [ ] No real IPs/hostnames/credentials in anything outside `local/`
      (grep your diff before pushing)
- [ ] Cross-referenced docs updated if behavior changed (`AGENTS.md`,
      `docs/OPERATIONS.md`, `docs/TROUBLESHOOTING.md` as relevant)
- [ ] New config added as a generic `*.template`/`*.example` if it needs
      deployment-specific values
