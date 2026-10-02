# Ježíšek

Rodinný seznam vánočních přání. Každý si zapíše svá přání (vidí je všichni). Ostatní u nich odškrtávají, co kupují. To obdarovaný nevidí.

## Jak to funguje

- **Přihlášení:** jen e-mailem, bez hesla. Pustí dovnitř jen e-maily ze seznamu (Nastavení → Správa rodiny, vidí jen správce).
- **Moje přání:** název, popis, priorita (1–3 ★), poznámka, fotka.
- **Přání ostatních:** výběr osoby → její přání + tipy od ostatních. Stavy nákupu: *Volné → Kupuji → Objednáno → Koupeno*. Dá se „složit se“.
- **Další obdarování:** dárky pro lidi mimo aplikaci (babičky…). Osobu i dárky přidává a upravuje kdokoli, všichni vidí vše včetně nákupů.
- **Tip na dárek:** přání zapsané za někoho jiného. Ten ho nevidí.
- **Zrušené přání:** když ho někdo kupuje, zůstane mu viditelné s upozorněním, dokud ho kupující neodebere.
- **Nový ročník:** správce po Vánocích založí nový rok. Stará data zůstanou v databázi, nesplněná přání lze přenést.
- **Upozornění e-mailem:** každý si v Nastavení zaškrtne, o čem chce vědět. Posílá se souhrnně jednou za hodinu.

## Technika

- Statický web (`index.html`, `app.js`, `style.css`) bez sestavování. Supabase JS z CDN.
- Supabase projekt `jezisek` (`encicvbzmsvmxgjmytmx`, Frankfurt).
  - Tabulky mají RLS bez politik, takže z prohlížeče nejsou čitelné. Vše jde přes funkce v `supabase/migrations/001_init.sql`. Ty podle e-mailu vrací jen to, co daný člověk smí vidět.
  - Fotky: veřejný bucket `photos`. Fotka se před nahráním zmenší na 1280 px.
  - Upozornění: tabulka `outbox` → edge funkce `send-notifications` (pg_cron každou hodinu v :07) → SMTP.
- **Bezpečnost je záměrně minimální** (rodinná aplikace): kdo zná cizí e-mail ze seznamu, může se za něj přihlásit.

## Změny databáze

Migrace jsou v `supabase/migrations/`. SQL s příkazy `DROP` nebo `DELETE` je potřeba spustit ručně v [SQL editoru](https://supabase.com/dashboard/project/encicvbzmsvmxgjmytmx/sql/new), protože nástroj Supabase ho bez potvrzení odmítne. Staré verze funkcí se nemažou, jen se přesměrují na nové.

## Zprovoznění e-mailových upozornění

V Supabase → Edge Functions → Secrets nastav:

| Secret | Hodnota |
|---|---|
| `SMTP_USER` | Gmail adresa, ze které se bude posílat |
| `SMTP_PASS` | heslo aplikace z Google účtu (Zabezpečení → Dvoufázové ověření → Hesla aplikací) |
| `APP_URL` | adresa aplikace (odkaz v e-mailu) |

Bez nich se upozornění jen hromadí v databázi a nic se neposílá.

## Nasazení

GitHub → Settings → Pages → Deploy from a branch → vybrat větev a `/ (root)`.
