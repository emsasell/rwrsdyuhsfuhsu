# EMCHAT PRO V6.1 FULL — DEVICES FIX

Полная версия Telegram-подобного мессенджера для Vercel + Supabase + Vercel Blob.

## Реализовано

- регистрация и вход;
- постоянная Supabase-сессия (`persistSession` + `autoRefreshToken`);
- реальные пользователи и профили;
- username, имя, био и аватар;
- личные сообщения по username;
- группы и каналы;
- приглашение пользователя по username;
- ссылка-приглашение `/join/...`;
- фото, видео, аудио и файлы до 50 МБ;
- Vercel Blob для файлов, не Supabase Storage;
- удаление и редактирование своих сообщений;
- ответы;
- закрепление и открепление сообщений;
- владельцы и администраторы;
- отдельные права администраторов;
- кик, бан, разбан, мут;
- список забаненных;
- передача владельца;
- изменение названия, описания и аватара группы/канала;
- список устройств с текущим устройством;
- автоматическая регистрация устройства при входе;
- обновление активности устройства;
- кик других устройств с автоматическим выходом кикнутого клиента из EMCHAT;
- защита от ложного выхода при временной ошибке загрузки устройств;
- realtime обновление сообщений;
- адаптивный мобильный интерфейс.

## Установка БЕЗ терминала

### 1. Supabase

1. Открой свой проект Supabase.
2. Перейди в **SQL Editor → New query**.
3. Открой `supabase/schema.sql` из этого архива.
4. Скопируй весь текст и нажми **Run**.
5. Если SQL уже запускался частично раньше, сначала запусти `supabase/devices_hotfix.sql`, затем полный `supabase/schema.sql`.
6. После SQL обнови страницу EMCHAT: текущее устройство создаётся автоматически.

### 2. Vercel Blob

В Vercel:

**Storage → Create → Blob → Connect to Project**.

После подключения Vercel обычно создаёт `BLOB_READ_WRITE_TOKEN` автоматически. Проверь это в **Project → Settings → Environment Variables**.

### 3. Переменные Vercel

Добавь:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
- `BLOB_READ_WRITE_TOKEN`

Значения Supabase находятся в **Supabase → Project Settings → API**.

### 4. GitHub

Распакуй ZIP и загрузи **содержимое папки `EMCHAT-PRO-V6-FULL` в корень репозитория**.

Важно: не должно получиться:

`репозиторий/EMCHAT-PRO-V6-FULL/app/...`

Нужно:

`репозиторий/app/...`

Обязательно замени старые:

- `package.json`
- `app/`
- `components/`
- `lib/`
- `supabase/`
- `tsconfig.json`
- `next.config.ts`

### 5. Vercel

После Commit Vercel начнёт новый Deploy автоматически.

Если Vercel показывает старую ошибку, используй **Redeploy** и очистку build cache, если Vercel предлагает эту опцию.

## Важно

Для загрузки файлов используется `/api/upload/route.ts` и актуальный обработчик `handleUpload` с обязательным `onUploadCompleted`, поэтому исправлена ошибка предыдущей сборки:

`Property 'onUploadCompleted' is missing`.

Проект не использует Tailwind, поэтому ошибки `Cannot find module 'tailwindcss'` здесь не должно быть.


## V6.2 FINAL IMPORTANT
Run `supabase/schema.sql` once. It now drops the legacy `get_my_devices()` helper before recreating it, so old databases no longer fail with `cannot change return type` and the whole migration no longer rolls back.


## V7.0 FINAL FIX
1. Run `supabase/V7.0-FINAL-CREATE-AVATAR-FIX.sql` once in Supabase SQL Editor.
2. Deploy this archive to Vercel. The client now calls `create_chat_v7`, avoiding stale `create_chat_full` schema-cache parameter names.
3. Profile avatar layout is fixed and device bootstrap no longer logs the account out because of a temporary missing device row.

## V7.2 urgent database fix
If you see `column "kind" of relation "chats" does not exist`, run `supabase/V7.2-CHATS-COMPAT-FIX.sql` in Supabase SQL Editor once, then refresh the app.


## V7.3 urgent Supabase fix
Run `supabase/V7.3-CHATS-COMPAT-SYNTAX-FIX.sql` as one query. It fixes the V7.2 nested dollar-quote syntax error near `update` and safely migrates legacy `chats.type` to `chats.kind`.
