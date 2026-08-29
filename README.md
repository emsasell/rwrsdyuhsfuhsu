# EMCHAT FULL

Полноценный мессенджер: регистрация, реальные пользователи, личные чаты, группы, фото/файлы, аватары, редактирование и удаление сообщений.

## Установка
1. npm install
2. Создайте Supabase project.
3. Выполните supabase/schema.sql в SQL Editor.
4. Создайте .env.local из .env.example и вставьте URL + Publishable Key.
5. В Supabase Authentication настройте Site URL для Vercel.
6. npm run dev

## Vercel
Добавьте те же две переменные окружения. Не добавляйте service_role key в браузер.

## Примечание
Для более строгого production-доступа к файлам рекомендуется заменить public URLs на signed URLs и расширить Storage RLS.
