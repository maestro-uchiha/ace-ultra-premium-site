# Amaterasu Static Deploy (ASD) — Template

A tiny static boilerplate that “bakes” HTML files using a shared `layout.html`, fixes paths for GitHub Pages subfolders, auto-builds `sitemap.xml`, preserves a strict `robots.txt`, and ships helper scripts for posts, pagination, and redirects.

- **Changelog:** see [CHANGELOG.md](./CHANGELOG.md)
- **Current version:** `v1.1.0`
- **Works with:** GitHub Pages (project subpath) and custom domains
- **Stack:** Plain HTML/CSS + PowerShell scripts (Windows-friendly)

---

## Quick start

```powershell
# 1) Allow scripts (first time only)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# 2) Clone your site
git clone https://github.com/maestro-uchiha/ace-ultra-premium-site.git
cd ace-ultra-premium-site\parametric-static

# 3) Bake the site (wrap pages + sitemap + robots sitemap URL)
.\scripts\bake.ps1 -Brand "Ace Ultra Premium" -Money "https://acecartstore.com"

## License

**Proprietary – All rights reserved.**  
No permission is granted to use, copy, modify, or redistribute this repository or any part of it without
explicit written permission from the copyright holder.
