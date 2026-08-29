# EMCHAT PRO V2
Полный мессенджер: профили, ЛС, группы, каналы, ссылки-приглашения, фото/видео/файлы до 50 МБ, Vercel Blob, редактирование/удаление сообщений, устройства и кик, постоянная Supabase-сессия.

## Без терминала
1. Распаковать ZIP.
2. Загрузить содержимое папки в GitHub через Upload files.
3. Выполнить supabase/schema.sql целиком в Supabase SQL Editor.
4. В Vercel импортировать GitHub-проект.
5. Environment Variables:
   NEXT_PUBLIC_SUPABASE_URL
   NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
6. Vercel → Storage → Create → Blob → подключить к этому проекту. Vercel автоматически создаст BLOB_READ_WRITE_TOKEN.
7. Redeploy.

Файлы до 50 МБ отправляются напрямую из браузера в Vercel Blob, а не через Vercel Function.

## V3 moderation
- Владельцы и администраторы групп и каналов могут менять название, описание и аватар.
- Владелец управляет администраторами.
- Администраторы могут мутить, кикать и банить обычных участников.
- Владелец имеет полный доступ к модерации.
- Бан запрещает повторный вход по ссылке-приглашению.


## V4 moderation and ownership
- banned users list with **Unban** button;
- owner transfer with a Crown SVG icon;
- pinned message banner with Pin SVG icon;
- individual administrator permissions: kick, ban/unban, mute, edit chat info, invite links, pin messages, and send in channels.

After updating from V3, run the complete `supabase/schema.sql` again. It contains safe `add column if not exists` migrations and replaces the moderation functions.
