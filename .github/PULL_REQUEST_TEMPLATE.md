> Reminder: `opencode.yml` and helper workflows must stay byte-identical
> across `main`, `beta` and `dev` — child workflows resolve by tag, and a
> diverged workflow file would rebuild the wrong kit.
