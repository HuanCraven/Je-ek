-- Jednou za hodinu (v :07) zavolá edge funkci send-notifications.
-- Autorizace anon klíčem stačí – funkce jen rozešle čekající upozornění.
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.schedule('send-notifications', '7 * * * *', $$
  select net.http_post(
    url := 'https://encicvbzmsvmxgjmytmx.supabase.co/functions/v1/send-notifications',
    headers := '{"Content-Type": "application/json", "Authorization": "Bearer <ANON_KEY>"}'::jsonb,
    body := '{}'::jsonb)
$$);
