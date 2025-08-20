# Amaterasu Static Deploy — Parametric Static Microsite Template

Baked partials, legit pages, and an auto blog index on free hosts (GitHub Pages, Netlify, Vercel, Cloudflare).

## Quick Start
1) Edit page content and set `config.json → site.url`.
2) Bake (Windows):
   ```powershell
   cd parametric-static 
   scripts\bake.bat "{{BRAND}}" "https://YOUR-DOMAIN.com"
