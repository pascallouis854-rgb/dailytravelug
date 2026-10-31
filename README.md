# Daily Travel - GitHub Ready (Fixed)

## FIXED VERSION - Works on GitHub Pages

This version fixes the previous zip issue:
- Removed duplicate files
- Hidden badge but kept Supabase connection alive
- Supabase URL: https://qjffybockawpfpvanpzw.supabase.co injected correctly
- No stats on first screen (removed per request)
- Cross-device login enabled

### Files (ONLY 5 HTML + assets)
- index.html -> Main app (customer + company) - GitHub Pages serves this
- client.html -> Same as index
- admin.html -> Admin panel
- assets/logo.jpg

### How to Upload to GitHub (Will Work Now)

1. Create repo `daily-travel` on GitHub
2. Upload ALL files from this zip to repo root (drag and drop)
3. Wait for commit
4. Go to Settings -> Pages -> Source: Deploy from branch -> Branch: main -> Folder: / (root) -> Save
5. Wait 1-2 minutes, refresh Pages, your link appears: https://YOURNAME.github.io/daily-travel/

6. Open that link - it works now (no blank screen).

### If Still Blank on GitHub

Common fix: GitHub Pages caches old version. Add ?v=2 to URL: https://YOURNAME.github.io/daily-travel/?v=2

Or check: index.html must be at root, not inside a folder.

### Supabase Setup (Do This First)

1. Supabase Dashboard -> SQL Editor -> Paste & Run supabase.sql
2. Table Editor -> platform_settings id=1 -> Set admin_mtn_code = your MTN code (256...)
3. Now registration and login will sync across devices.

### Payments

- Registration fee -> goes to your admin_mtn_code
- Ticket sales -> splits: company gets base price, you get commission
- Customer sees ONLY final total price
- Simulation mode until you add MTN API keys to Edge Functions Secrets.

BOOK • RIDE • EXPLORE
