# Publishing IOU

The repository publishes installable ZIPs to GitHub and CurseForge project **1746575**. Pushing code to `main` runs checks; publishing requires a matching `v<version>` tag.

Use normal `X.Y.Z` versions and CurseForge's **Release** channel by default. This makes updates available to CurseForge app users with the default release preference. Create an alpha, beta, or other prerelease only when the owner explicitly requests it. An opt-in experimental feature can remain clearly described within a normal release; the channel does not imply live testing was performed.

## Actions configuration

- Repository secret **CF_API_KEY**: the CurseForge author upload token. It is used only in the upload job and is never stored in the addon, ZIP, or repository.
- Repository variable **CF_PROJECT_ID**: `1746575`. This is public project metadata, separate from the secret.

Use an author upload token from [CurseForge API Tokens](https://authors.curseforge.com/account/api-tokens). The [upload API](https://support.curseforge.com/support/solutions/articles/9000197321-curseforge-upload-api) uses that token to upload to an existing project; adding a secret by itself does not trigger an upload.

## Tagged release

1. Update the TOC/core version and changelog. Run the Lua regression harness, publishing tests, and version-matched package builder.
2. Commit using the repository's PhilForever identity and push an annotated matching tag.
3. **Release addon** tests and builds the tag, creates the GitHub release, then calls **Publish CurseForge** with the same tag.

The CurseForge job downloads the GitHub ZIP/checksum and validates their contents and TOC version. It resolves Forever `1.60.1` against CurseForge's current game-version API, then uploads the exact ZIP. Normal `X.Y.Z` versions are CurseForge Releases and regular GitHub releases. An explicitly requested `-alpha` build uses Alpha; beta/RC builds use Beta. GitHub prereleases do not replace the latest normal release.

A successful upload returns a file ID. CurseForge processing or moderation can still delay public visibility, especially for a new project. The job records `curseforge-upload.json` on the GitHub release so repeating an upload can reuse the matching receipt without creating another file. An intent is retained before contacting CurseForge; an intent without a receipt blocks automatic retries. Inspect the project's files and reconcile that attempt before removing an unresolved intent or retrying.

## Publish an existing GitHub release

Run **Actions > Publish CurseForge > Run workflow**, select `main`, and provide an existing tag such as `v0.2.0`. This backfills the existing verified artifact without moving its tag or changing its ZIP. It does not publish an untagged working tree.

If upload fails, inspect that job's error and confirm the token belongs to an author with upload access to project 1746575. Keep the token in Actions; never paste it into an issue or chat.
