# from the repository root
@"
# Changelog

## v1.1.0 — Stable whitespace + robots defaults
- Trim + normalize whitespace inside `<main>` during bake.
- Keep strict default `robots.txt`; bake appends only the absolute `Sitemap:` line from `config.site.url`.
- Safer root-link rewriting for GitHub Pages subpaths.
- Blog index builder prefers `<title>`, then `<h1>`, then filename.

## v1.0.0 — Initial release
- Parametric static template, layout wrapper, sitemap generation.
- Basic posts tooling, manual bake, GitHub Pages workflow.
"@ | Set-Content -Encoding UTF8 CHANGELOG.md

git add CHANGELOG.md
git commit -m "docs: add CHANGELOG.md for v1.1.0"
git push

## 1.1.0 - 2025-08-24
- Wizard end-to-end OK
- Pagination, redirects manager, link checker
- Bake & sitemap/robots auto-gen
