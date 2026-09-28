# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Email **support@thinkany.ai** with:

- a description of the issue and its impact,
- steps to reproduce (proof-of-concept if possible),
- any suggested fix.

We aim to acknowledge reports within a few business days and will keep you updated as we
investigate and ship a fix. Responsible disclosure is appreciated — please give us a reasonable
window to release a patch before any public disclosure.

## Scope notes

- Spotcat is **BYOK**: model provider keys are entered by the user (or imported from Termany)
  and stored locally in `~/Library/Application Support/Spotcat/models.json` (mode 600). They are never committed to this
  repository or sent anywhere other than the provider the user configured.
- Extensions run in a `WKWebView` and reach native features only through `window.spotcat`.
  Sensitive capabilities are gated by manifest permissions (`network`, `ai`). Reports about
  permission bypasses, reading files outside an extension's own folder, or escaping the page
  (e.g. script injection into the launcher or chat) are in scope.
- Release builds are signed with a Developer ID and notarized; signing material lives only in
  the maintainers' keychains and GitHub Actions secrets.
