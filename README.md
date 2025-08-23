# Ace Ultra Premium — Amaterasu Static Deploy (ASD)

**ASD** is a tiny, fast static site workflow optimized for backlink microsites and simple product blogs.  
This repo is the Ace Ultra Premium site built with ASD.

## What you get

- **Layout-based baking** (`layout.html` + `bake.ps1`) — no runtime includes.
- **Parametric content** with tokens: `{{BRAND}}`, `{{MONEY}}`, `{{YEAR}}`.
- **Pagination** for `/blog/` (page size configurable).
- **Redirect Manager** (`redirects.ps1`) with `redirects.json` + Service Worker + 404 fallback.
- **GH Pages + Custom Domain** safe routing (works under subpaths and roots).
- **SEO niceties**: HTML+XML sitemap, RSS feed, meta, OG/Twitter, clean HTML.
- **Utilities**: link checker, new/rename/delete post helpers.

---

## Repo structure

> CI: `.github/workflows/` deploys **`parametric-static/`** to GitHub Pages.

---

## Requirements

- **Windows + PowerShell** (5.1 or 7+)
- **Git**
- (Optional) **VS Code**
- First run only, allow scripts:
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned


---

## Quick sanity check (optional)
1) Create the config file:
```powershell
Set-Content -Encoding UTF8 .\parametric-static\bake-config.json @'
{
  "brand": "Ace Ultra Premium",
  "url": "https://acecartstore.com"
}
'@
