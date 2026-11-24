# Sorbet (static + runtime type checking)

dev is typed with [Sorbet](https://sorbet.org): `sorbet-runtime` checks sigs at runtime (a runtime dependency, from the gemspec), `sorbet` checks statically (development group), and [Tapioca](https://github.com/Shopify/tapioca) generates the gem RBIs under `sorbet/rbi/gems/`. Versions float with `Gemfile.lock`; nothing is pinned for Sorbet's sake. The Ruby is the one `dependencies.rb` locks.

## Commands

- **`dev typecheck`** — verifies the gem RBIs match `Gemfile.lock` (`tapioca gem --verify`), then runs `srb tc`. Out-of-date RBIs fail with the instruction to run `dev rbi` and commit. CI runs the same command.
- **`dev rbi`** — regenerates `sorbet/rbi/gems/` (`tapioca gem`). Run it after any change to `Gemfile.lock` and commit the result.

## Strictness

- `lib/**` is `# typed: strict`, enforced by `Sorbet/StrictSigil` in `.rubocop.yml`. The few `typed: false` holdouts are listed there with the Sorbet error each works around.
- Tests are `# typed: false`: RSpock's AST transform and the type pinnings in setup methods do not typecheck. A sigil is still required (`Sorbet/ValidSigil` from the org tier).

## Annotations

`sorbet/rbi/annotations/` holds community annotations from [rbi-central](https://github.com/Shopify/rbi-central), pulled by `bin/tapioca annotations`. `dev rbi` does not touch them.

The committed copies carry two local edits, made when dev was on sorbet 0.5.x; after a `tapioca annotations` run, check `srb tc` and re-apply whichever still fails:

- `minitest.rbi` — `assert_raises`: the two overloaded sigs merged into one, with `NilClass` added to the union (error 5040 at the time).
- `mocha.rbi` — `Expectation#with`: the annotation's sig removed; the generated RBI's definition conflicted with it (error 4010).

## References

- [Adopting Sorbet](https://sorbet.org/docs/adopting)
- [Tapioca — Keeping RBI files for gems up-to-date](https://github.com/Shopify/tapioca?tab=readme-ov-file#keeping-rbi-files-for-gems-up-to-date)
