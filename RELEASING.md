# Releasing Steward

There is no separate publish step. Installed servers and Community Applications both read
`steward.plg` from the raw URL of the `main` branch, so **a merge to `main` is a release**.
Everything below follows from that.

## How a release reaches users

| Who | Reads | When |
| --- | --- | --- |
| Servers that have Steward installed | `https://raw.githubusercontent.com/hom-wang/steward/main/steward.plg` | When the owner clicks *Check for Updates* on the Plugins page, or on the schedule set in *Settings -> Notifications -> Plugin update check*, if the owner has set one |
| Community Applications | the same URL, through its app feed | The feed is rebuilt every few hours; each server then refreshes its own copy |

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
automatically. When a release branch is deleted, GitHub retargets PRs still open against it to
`main`, where the release check rejects them if they ship anything: retarget them to the next release
branch.

CI runs on pull requests and on pushes to `main`, not on pushes to release or feature branches: a
fresh release branch still carries the old version, and its CI result is the one on its PR.

## Rules

1. **The version is the release date**, the day the release branch is merged into `main`:
   `YYYY.MM.DD`, zero-padded. A second release on the same day appends `.1`, then `.2`, up to `.9`.
   Never use `.10`: string comparison sorts `2026.10.26.10` before `2026.10.26.9`. The version must
   also sort after the one on `main`; if `main` already carries today's date or a later one, use the
   next suffix of `main`'s version instead (e.g. `2026.10.25.2` after `2026.10.25.1`).
2. **Branch name and version agree.** On `release/v2026.10.26`, `steward.plg` and `steward.sh` say
   `2026.10.26`, and the first `<CHANGES>` entry is `### 2026.10.26`. The first shipped PR into the
   release branch sets the version; later PRs only add lines under that `<CHANGES>` heading. A PR that
   ships nothing may land before the version is set.
3. **Anything inside `steward.plg` ships**: `steward.plg` itself, `steward.sh` and `skills/`. A release
   that changes any of them has a version that sorts after the one on `main`.
4. **If the release slips to another day, re-date it before merging**: create `release/v<new date>`
   from the old release branch, change the version and the `<CHANGES>` heading there (through a PR
   into the new branch), open its PR to `main` and close the old one. Then retarget any PRs still open
   against the old branch and delete it; a closed, unmerged branch is not deleted automatically.
5. **Never go back.** A bad release is fixed by a new, higher version, not by reverting `main` to an
   older version string; servers that already updated would not see the older version as an update.
   An urgent fix gets its own release branch, e.g. `release/v2026.10.26.1`.
6. **These never change**, because installed servers find updates through them: the plugin name
   `steward`, the `pluginURL` in `steward.plg`, the `PluginURL` in `plugins/steward.xml`, the path of
   `plugins/steward.xml`, and the repository name.
7. **Nothing private is committed**: no keys, tokens, passwords, e-mail addresses, IP or MAC
   addresses, Unraid GUIDs, or details of a particular server. `tests/run-all.sh` scans for these and
   CI runs gitleaks over the whole history.

`tests/release-check.sh` checks, against `main`: the version format and that it sorts after `main`'s
(not that it is the actual merge date), the first `<CHANGES>` heading, the branch flow of rules 2 and
3, that a changed skill raises its `skill-version`, the pinned Claude Code checksum format, and the
update URL, plugin name and listing path of rule 6. CI runs it on every pull request with the PR's
target and source branch; `tests/run-all.sh` runs it locally against `origin/main`, uncommitted edits
included, without the branch flow. `tests/run-all.sh` separately checks that `steward.plg` and
`steward.sh` carry the same version.

## Cutting a release

1. Create the release branch from `main` and push it:

   ```
   git fetch origin main
   git checkout -b release/v2026.10.26 origin/main
   git push -u origin release/v2026.10.26
   ```

2. For each change, branch off the release branch and open a PR against it (not against `main`).
   - The first shipped PR sets the version in `<!ENTITY version "...">` in `steward.plg` and
     `STEWARD_VERSION="..."` in `steward.sh`, and adds the `### <version>` entry at the top of
     `<CHANGES>` in `steward.plg`.
   - Later PRs branch off the release branch after that and add their lines under the same heading,
     written for users: what changes for them, not how it was implemented.
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

## Testing a development build

Never install a branch's `steward.plg` as it is. It already carries the version of the coming release,
so a server running it would see the real release as the same version and never offer it, and the
server would claim to run a release it does not. Build a development copy instead:

```
tests/dev-install.sh
```

It writes `/tmp/steward-dev/steward.plg` with the version `<main's version>-dev.<commit>` (plus
`.dirty` for uncommitted changes to shipped files), e.g. `2026.10.25.1-dev.c6a1b14`. That sorts after
the version on `main` and before any later release, so once the release is merged the server offers it
on the Plugins page like any other update, which also tests the update path users take. The repository
keeps its real version.

The script prints the install command. `plugin install` refuses the same or an older version, so the
first development copy over a release, or a rebuild of the same commit, needs `forced`; the script says
when. Installing restarts the Steward service and drops Remote Control sessions for a few seconds; run
from a session inside the service, the plugin waits 10 seconds and restarts it in the background.

## Releasing

1. When everything planned is merged into the release branch, install a development build of it
   (above) on a test server and check *Settings -> Steward*, `steward status` and a Remote Control
   session.
2. Open the PR from `release/v<version>` to `main`. Title: `Steward <version>`; the body lists the
   PRs it contains.
3. On the release date, make sure the release branch is up to date with `main` and CI is green, then
   merge with a merge commit. If docs or CI changes landed on `main` while the release was open, bring
   them in locally (`git merge origin/main` on the release branch), resolve any conflicts keeping both
   sides, and push; GitHub's *Update branch* button cannot resolve conflicts.
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
