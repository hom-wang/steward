# Releasing Steward

There is no separate publish step. Installed servers and Community Applications both read
`steward.plg` from the raw URL of the `main` branch, so **a merge to `main` is a release**.
Everything below follows from that.

## How a release reaches users

| Who | Reads | When |
| --- | --- | --- |
| Servers that have Steward installed | `https://raw.githubusercontent.com/hom-wang/steward/main/steward.plg` | When the owner clicks *Check for Updates* on the Plugins page, or on the schedule set in *Settings -> Notifications -> Plugin update check* (off by default) |
| Community Applications | the same URL, through its app feed | The feed is rebuilt roughly every 4 hours; each server then refreshes its own copy |

Both compare only the `version` string, as plain text. A content change without a version change is
never offered to existing installs, while new installs get the new content: the same version number
then means two different things.

## Branches

```
feature/... --PR--+
fix/...     --PR--+--> release/v2026.10.26 --PR--> main   (the release)
feature/... --PR--+
```

- **`main`** is what users run. It only receives pull requests. Shipped changes come only from a
  `release/v<version>` branch; changes that do not ship (README, docs, tests, CI, the CA listing) may
  go straight from their own branch to `main`.
- **`release/v<version>`** collects everything going out in one release. It is created from `main`,
  named after the planned release date, and receives the feature and fix branches through pull
  requests.
- **Feature and fix branches** are created from the release branch they target and open their PR
  against it.

`main` is protected: a PR is required, the `check` CI job must pass on a branch that is up to date
with `main`, conversations must be resolved, and force pushes and branch deletion are blocked. This
applies to administrators too. Merged branches, including the release branch, are deleted
automatically.

## Rules

1. **The version is the release date**, the day the release branch is merged into `main`:
   `YYYY.MM.DD`, zero-padded. A second release on the same day appends `.1`, then `.2`, up to `.9`.
   Never use `.10`: string comparison sorts `2026.10.26.10` before `2026.10.26.9`.
2. **Branch name and version agree.** On `release/v2026.10.26`, `steward.plg` and `steward.sh` say
   `2026.10.26`, and the first `<CHANGES>` entry is `### 2026.10.26`. Every PR into the release branch
   leaves it that way; the first one to land sets the version.
3. **Anything inside `steward.plg` ships**: `steward.plg` itself, `steward.sh` and `skills/`. A release
   that changes any of them has a version that sorts after the one on `main`.
4. **If the release slips to another day, re-date it before merging**: create `release/v<new date>`
   from the old release branch, change the version and the `<CHANGES>` heading, open its PR to `main`
   and close the old one.
5. **Never go back.** A bad release is fixed by a new, higher version, not by reverting `main` to an
   older version string; servers that already updated would not see the older version as an update.
   An urgent fix gets its own release branch, e.g. `release/v2026.10.26.1`.
6. **These never change**, because installed servers find updates through them: the plugin name
   `steward`, the `pluginURL` in `steward.plg`, the `PluginURL` in `plugins/steward.xml`, the path of
   `plugins/steward.xml`, and the repository name.
7. **Nothing private is committed**: no keys, tokens, passwords, e-mail addresses, IP or MAC
   addresses, Unraid GUIDs, or details of a particular server. `tests/run-all.sh` scans for these and
   CI runs gitleaks over the whole history.

`tests/release-check.sh` checks rules 1, 2, 3 and 6 and the branch flow; CI runs it on every pull
request with the PR's target and source branch.

## Cutting a release

1. Create the release branch from `main` and push it:

   ```
   git fetch origin main
   git checkout -b release/v2026.10.26 origin/main
   git push -u origin release/v2026.10.26
   ```

2. For each change, branch off the release branch and open a PR against it (not against `main`).
   In the first PR, or in each PR if they may land in any order:
   - set the version in `<!ENTITY version "...">` in `steward.plg` and `STEWARD_VERSION="..."` in
     `steward.sh`;
   - add or extend the `### <version>` entry at the top of `<CHANGES>` in `steward.plg`, written for
     users: what changes for them, not how it was implemented.
3. If a skill changed, raise its `skill-version` to the release date and, if it was re-checked
   against a newer Unraid, its `unraid-verified` and `unraid-applies`.
4. To move to a newer Claude Code, update `CLAUDE_PIN_VERSION` and `CLAUDE_PIN_SHA256` in
   `steward.sh`. Take the checksum from Anthropic's manifest, never from a downloaded file:

   ```
   curl -fsS https://downloads.claude.ai/claude-code-releases/<version>/manifest.json \
     | jq -r '.platforms["linux-x64"].checksum'
   ```

   The pin only affects first installs and restoring the backup; installed servers keep updating
   Claude Code by themselves and verify each update against the same manifest.
5. Copy `steward.sh` into the main script block of `steward.plg`, and each `skills/<name>/SKILL.md`
   into its `<FILE>` block. `tests/run-all.sh` fails if any embedded copy differs.
6. Run `tests/run-all.sh` (the full run, including the smoke test) before each PR.

## Releasing

1. When everything planned is merged into the release branch, install its `steward.plg` on a test
   server and check *Settings -> Steward*, `steward status` and a Remote Control session.
2. Open the PR from `release/v<version>` to `main`. Title: `Steward <version>`; the body lists the
   PRs it contains.
3. On the release date, make sure the release branch is up to date with `main` and CI is green, then
   merge with a merge commit.
4. Tag the merge commit and push the tag: `git tag v<version> <merge commit> && git push origin v<version>`.
   Tags are milestones for people; Unraid does not use them.
5. Confirm the raw URL serves the new version (GitHub's raw cache can take a few minutes):

   ```
   curl -fsS https://raw.githubusercontent.com/hom-wang/steward/main/steward.plg | grep 'ENTITY version'
   ```

6. Within a few hours, check that the Apps page in Community Applications shows the new version.

## Community Applications

The listing was submitted once through the CA portal and is not resubmitted for releases. CA's
automated review may open issues or pull requests against this repository; a fix it asks for goes
through a release branch like any other shipped change, and replies posted by an AI assistant say so.
