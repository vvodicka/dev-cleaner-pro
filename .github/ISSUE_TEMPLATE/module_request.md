---
name: Module request
about: A tool that eats disk space and is not covered yet
title: ''
labels: module
assignees: ''
---

**Tool**

**Paths it fills**, and roughly how big they get:

```
~/…
```

**Does the tool clean up after itself?** (e.g. `npm cache clean --force`,
`docker system prune`.) The app prefers a tool's own command over deleting the
directory underneath it.

**How risky is losing it** — regenerates on its own, only costs a rebuild, or gone for good?

**Anything that must never be deleted inside those paths** (config, credentials, licences).
