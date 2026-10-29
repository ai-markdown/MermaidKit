# Contributor Guidelines

This repository is the AI Markdown fork of [2389-research/MermaidKit](https://github.com/2389-research/MermaidKit). It provides the default native Mermaid diagram renderer for the optional `AIMarkdownMermaid` product of [ai-markdown-swift](https://github.com/ai-markdown/ai-markdown-swift).

## Branches and baseline

- Maintain AI Markdown changes on the `ai-markdown` branch, which is the default branch of this fork.
- Preserve the upstream `main` branch as a mirror of upstream. Never commit AI Markdown changes to it or rewrite its history.
- The `ai-markdown` branch starts from upstream commit `fab34c2b1b3fa9dd10aded00863a11b1258abcb1` (upstream `main` after `v2.9.1`, the revision measured in the evaluation; `v2.9.1` itself is `64c19fbddf5604122b01563b3ab727dbadf0ee95`), the version evaluated for AI Markdown. Do not combine maintenance changes with an upstream upgrade; adopting a newer upstream revision is a separate, explicitly reviewed change that must be revalidated.

## Consumption by ai-markdown-swift

- ai-markdown-swift declares this package as a remote SwiftPM dependency pinned by an exact `revision:` and records the same commit as the `Dependencies/mermaidkit` development submodule (`update = none`). Branch names never replace revision pins.
- Push commits to this fork first. Then update the parent repository's gitlink, `Package.swift` revision, `Package.resolved`, and `scripts/package-split/manifest.json` together.
- For co-development, run `bash scripts/dependencies.sh local` in ai-markdown-swift. It overrides the `mermaidkit` package with `swift package edit --path Dependencies/mermaidkit`, so uncommitted changes here are built directly. Switch back with `bash scripts/dependencies.sh remote` before committing the parent lock file.
- Only the optional `AIMarkdownMermaid` target of ai-markdown-swift may depend on this package. Its Engine, Core, and UI targets must not. Keep existing product and module names stable unless the parent repository is updated in the same release sequence.

## Repository constraints

- Preserve upstream licenses, copyright notices, and meaningful source data, including multilingual fixtures.
- Keep the `LinuxRaster` trait off by default so Apple consumers never resolve the Silica/Cairo branch dependencies.
- Known maintenance items: the `autonumber` integer overflow crash, silent failure for canvases of 4000 pt or more, `\r\n` input, and missing diagnostics for diagrams that render with dropped content. Report unsupported diagram types explicitly instead of silently narrowing scope.
- Write all new or modified development text in English, including documentation, code comments, diagnostics, log messages, test descriptions, and commit messages.
- Keep the package buildable with Swift 6 language mode for iOS 26 and macOS 26 consumers, and keep ordinary builds independent of the AI Markdown workspace or external generators.
- Keep upstream tests and add regression tests for each fix. Run checks appropriate to each change, and do not present historical results as new validation.

## Commit messages

- Follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) using `<type>[optional scope][!]: <description>`.
- Use `feat` for new functionality, `fix` for bug fixes, and other types such as `docs`, `test`, or `refactor` as appropriate.
- Describe what the commit changes. Add a body when needed to explain the behavior or reasoning, separated from the subject by a blank line.
- Mark breaking changes with `!` after the type or scope, or with a `BREAKING CHANGE: <description>` footer.
