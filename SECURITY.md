# Security

Report vulnerabilities privately through the repository's **Security → Report a vulnerability** page. Do not include passwords, access tokens, private keys, recovery codes, or unredacted logs in public issues or pull requests. Revoke an exposed credential with its issuer; deleting it from a file or Git history does not invalidate it.

## Repository controls

The public repository uses pull requests, passing platform checks, signed commits on `main`, and blocked force pushes/deletions. Release tags are protected against replacement and deletion. The maintainer is the only collaborator; release publishing is a separate authenticated maintainer action, not a CI workflow permission.

CI uses GitHub-hosted, disposable runners and read-only repository tokens. It does not need repository secrets, cloud credentials, signing keys, or OIDC permissions. Checkout credentials are not persisted in Git configuration. Actions are pinned to full commit SHAs and restricted to the approved action revisions. External fork workflows require maintainer approval. Review all workflow and test-script changes before approving a run; a test script can execute arbitrary commands even when a workflow file is unchanged. Use only the current reviewed commit when rerunning a workflow.

Dependency updates arrive as pull requests. Build timeouts and concurrency limits reduce accidental or abusive runner use. These controls reduce risk; they do not make a compromised account or a stolen administrator token safe. Maintain strong account authentication, review active sessions and installed applications, and revoke old or exposed credentials.

## Releases and app permissions

Download releases from this repository and verify the published SHA-256 checksums. Checksums detect file changes; they are not an independent publisher signature. The macOS app is ad-hoc signed and the Windows executable is unsigned. Neither installer disables operating-system security controls.

The apps make local power-management changes only. They do not need GitHub credentials, API keys, or network access. The macOS installer grants only its two specific sleep commands. Windows installation is per user; its temporary lid-policy changes are journaled and restored on off, expiry, quit, or crash recovery. Organization policies may prevent those changes. Windows does not have the macOS heat-cutoff feature.
