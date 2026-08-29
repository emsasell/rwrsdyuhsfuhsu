# EMCHAT PRO V7.4 FINAL

## What is fixed
- Message sending uses `send_chat_message` RPC and preserves a direct insert fallback.
- Online status is based on `profiles.last_seen` with a 45-second presence window.
- Presence is refreshed while the app is open.
- Devices are listed through a stable RPC; other devices can be kicked.
- No automatic logout is triggered by a transient database error.

## Deploy
1. Run `supabase/V7.4-FINAL-ONLINE-MESSAGES-FIX.sql` in Supabase SQL Editor.
2. Deploy the project to Vercel.
3. Open EMCHAT, refresh once, then test messages, chat creation, devices and online status.

Keep the older SQL files only as history; V7.4 is the migration to run for this update.
