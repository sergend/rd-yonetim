// belge-dogrula: yüklenen belge dosyasının SHA-256 özetini sunucuda hesaplar
// ve yüklemeyi tamamlar (migration 20261107000000).
//
// 1. Kullanıcının oturumuyla `document_upload_target`: belge bu kullanıcının
//    bekleyen (veya tamamlanmış) yüklemesi mi? Yetki veritabanında denetlenir.
// 2. Sunucu anahtarıyla Storage'dan gerçek baytları indirir, SHA-256 ve boyutu
//    hesaplar, `record_document_server_hash` ile kaydeder (yalnızca service_role).
// 3. Kullanıcının oturumuyla `complete_document_upload`: sunucu özeti beyan
//    edilenle aynı değilse belge "yüklendi" olmaz.
//
// Sunucu anahtarı yalnızca bu fonksiyonun ortamındadır; istemciye gitmez.
// Hata yanıtı PostgREST biçimindedir: { code, message } (ör. P0002, 23505).

const BUCKET = "belgeler";
const MAX_BYTES = 26214400;

type Json = Record<string, unknown>;

function reply(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}

function fail(status: number, code: string, message: string): Response {
  return reply(status, { code, message });
}

async function rpc(base: string, apikey: string, auth: string, name: string, args: Json) {
  const res = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey, Authorization: auth, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { code: "XX000", message: "Sunucudan beklenmeyen yanıt" };
  }
  return { ok: res.ok, status: res.status, body };
}

function hex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return fail(405, "PGRST000", "Yalnızca POST");
  const base = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!base || !anon || !service) return fail(500, "XX000", "Doğrulama servisi yapılandırılmamış");

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return fail(401, "PGRST301", "Oturum gerekli");

  let id: unknown;
  try {
    id = (await req.json())?.id;
  } catch {
    id = null;
  }
  if (typeof id !== "string" || !/^[0-9a-fA-F-]{36}$/.test(id)) return fail(400, "22023", "Geçersiz belge kimliği");

  // 1) Yetki ve hedef (kullanıcının oturumuyla)
  const target = await rpc(base, anon, auth, "document_upload_target", { p_id: id });
  if (!target.ok) return reply(target.status, target.body as Json);
  const row = (Array.isArray(target.body) ? target.body[0] : target.body) as
    | { status: string; storage_path: string; byte_size: number; server_verified: boolean }
    | undefined;
  if (!row) return fail(404, "P0002", "Belge bulunamadı");

  // 2) Gerçek baytların özeti (yalnızca bekleyen ve henüz doğrulanmamış yüklemede)
  if (row.status === "bekliyor" && !row.server_verified) {
    const path = row.storage_path.split("/").map(encodeURIComponent).join("/");
    const object = await fetch(`${base}/storage/v1/object/authenticated/${BUCKET}/${path}`, {
      headers: { apikey: service, Authorization: `Bearer ${service}` },
    });
    if (object.status === 404 || object.status === 400) {
      await object.body?.cancel();
      return fail(404, "P0002", "Dosya henüz yüklenmedi");
    }
    if (!object.ok) {
      await object.body?.cancel();
      return fail(502, "XX000", "Dosya sunucuda okunamadı; tekrar deneyin");
    }
    const bytes = await object.arrayBuffer();
    if (bytes.byteLength > MAX_BYTES) return fail(400, "23514", "Dosya çok büyük");
    const sha256 = hex(await crypto.subtle.digest("SHA-256", bytes));
    const recorded = await rpc(base, service, `Bearer ${service}`, "record_document_server_hash", {
      p_id: id,
      p_sha256: sha256,
      p_byte_size: bytes.byteLength,
    });
    if (!recorded.ok) return reply(recorded.status, recorded.body as Json);
  }

  // 3) Tamamlama (kullanıcının oturumuyla; özet uyuşmazsa 23505 döner)
  const done = await rpc(base, anon, auth, "complete_document_upload", { p_id: id });
  return reply(done.ok ? 200 : done.status, done.body as Json);
});
