// Rozešle nahromaděná upozornění z tabulky outbox – jeden souhrnný e-mail na člověka.
// Spouští ji pg_cron jednou za hodinu. Posílá přes SMTP (výchozí Gmail, port 465).
//
// Potřebné secrets (Supabase → Edge Functions → Secrets):
//   SMTP_USER  – odesílací adresa (např. rodina.jezisek@gmail.com)
//   SMTP_PASS  – heslo aplikace (u Gmailu: Účet Google → Zabezpečení → Hesla aplikací)
//   APP_URL    – adresa aplikace, vloží se do e-mailu jako odkaz
// Volitelně: SMTP_HOST (výchozí smtp.gmail.com), SMTP_PORT (výchozí 465)
import { createClient } from "jsr:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

Deno.serve(async () => {
  const user = Deno.env.get("SMTP_USER");
  const pass = Deno.env.get("SMTP_PASS");
  if (!user || !pass) {
    return Response.json({ skipped: "SMTP není nastaveno" });
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: rows, error } = await db
    .from("outbox")
    .select("id, message, member_id, members(email, name)")
    .is("sent_at", null)
    .order("id");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!rows.length) return Response.json({ sent: 0 });

  const byMember = new Map<string, { email: string; name: string; ids: number[]; lines: string[] }>();
  for (const r of rows as any[]) {
    const m = byMember.get(r.member_id) ??
      { email: r.members.email, name: r.members.name, ids: [], lines: [] };
    m.ids.push(r.id);
    m.lines.push(r.message);
    byMember.set(r.member_id, m);
  }

  const port = Number(Deno.env.get("SMTP_PORT") ?? 465);
  const transport = nodemailer.createTransport({
    host: Deno.env.get("SMTP_HOST") ?? "smtp.gmail.com",
    port,
    secure: port === 465,
    auth: { user, pass },
  });
  const appUrl = Deno.env.get("APP_URL") ?? "";

  let sent = 0;
  const failed: string[] = [];
  for (const m of byMember.values()) {
    const text = `Ahoj ${m.name},\n\nv Ježíškovi je něco nového:\n\n` +
      m.lines.map((l) => `• ${l}`).join("\n") +
      (appUrl ? `\n\nOtevřít Ježíška: ${appUrl}` : "") +
      `\n\nUpozornění si můžeš vypnout v aplikaci v Nastavení.`;
    try {
      await transport.sendMail({
        from: `Ježíšek <${user}>`,
        to: m.email,
        subject: "Ježíšek – novinky",
        text,
      });
      await db.from("outbox").update({ sent_at: new Date().toISOString() }).in("id", m.ids);
      sent++;
    } catch (e) {
      console.error("Odeslání selhalo", m.email, e);
      failed.push(m.email);
    }
  }
  return Response.json({ sent, failed });
});
