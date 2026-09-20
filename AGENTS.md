# Repository Instructions

## Release Notes

- Every release, including prereleases, must add a manually maintained `.github/release-notes/<tag>.md` before the release tag is created. Stable releases must also update `CHANGELOG.md`.
- Release-note files must contain non-empty `## 简体中文` and `## English` sections with equivalent user-facing content. Use `###` or lower for headings inside either language section.
- GitHub Releases must publish the matching file with `--notes-file`; do not replace it with generated notes.
- The release workflow must reject any release tag whose bilingual release-note file is missing or malformed.
- Never create or move a public release tag before the changelog and bilingual notes are committed. If an existing public Release body is wrong, edit the body without moving its tag.
