# Branch protection: main

Configure these rules in GitHub so merges to `main` are only allowed when CI is green and no one can push directly to `main`.

**GitHub:** Repo → **Settings** → **Branches** → **Add branch protection rule** (or edit the rule for `main`).

## Recommended settings

1. **Branch name pattern:** `main`

2. **Require a pull request before merging**
   - Enable this.
   - Optionally: set "Require approvals" (e.g. 1) if you want review.

3. **Require status checks to pass before merging**
   - Enable this.
   - Add required status check: **`test`** (this is the job name from `.github/workflows/test.yml`).
   - Optionally: enable "Require branches to be up to date before merging" so the PR must be rebased/merged with the latest `main` and re-run CI.

4. **Do not allow bypassing the above settings**
   - Leave "Allow specified actors to bypass required pull requests" **unchecked** (or restrict to admins only if you really need it).

5. **Restrict who can push to matching branches**
   - Enable "Do not allow bypassing the above settings" / ensure no one can push directly.
   - In practice, **do not** add "Allow force pushes" or "Allow deletions"; leave them disabled.

6. **Save** the rule.

After this, all changes to `main` must go through a pull request, and the **Test** workflow (status check name: `test`) must be green before merge.
