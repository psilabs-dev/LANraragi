# CUSTOM

Additional document commit to ensure that this branch is ALWAYS different from the default branch.

> `cr-dev` branch should never be the *source* of MRs; it can only the the *target* of MRs. No direct commits/pushes should be done on this branch. `cr-stable` should only merge towards `cr-dev` and no other branch.

- `cr-stable` includes (presumably) stable upstream commits and stable, divergent custom commits.
- `cr-dev` includes what `cr-stable` has, in addition to pending commits to upstream.

Diagram of merge flow:
```
dev@upstream => dev
dev => cr-stable => cr-dev
dev => feature/fix
feature/fix => cr-stable (if merge status decided in upstream)
feature/fix => cr-dev (if merge status undecided in upstream)
```