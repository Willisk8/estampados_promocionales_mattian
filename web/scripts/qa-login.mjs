/**
 * QA E2E helper: genera la cookie de sesion @supabase/ssr que el navegador
 * tendria tras un login real, usando el propio paquete del proyecto.
 *
 * Uso:
 *   node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON scripts/qa-login.mjs <userIndex>
 *
 * Salida: archivo jar (name=value por linea) en %TEMP%. Nunca imprime tokens.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServerClient } from "@supabase/ssr";

const rootWeb = process.cwd();
const readEnv = (name) => {
  const txt = readFileSync(join(rootWeb, "..", ".env.staging"), "utf8");
  const line = txt.split(/\r?\n/).find((l) => l.startsWith(name + "="));
  return line ? line.slice(name.length + 1).trim() : null;
};

const url = readEnv("SUPABASE_URL");
const anon = readEnv("SUPABASE_ANON_KEY");
const service = readEnv("SUPABASE_SERVICE_ROLE_KEY");
const password = readFileSync(join(rootWeb, "..", ".qa_test_account_password"), "utf8").trim();

if (!url || !anon || !service || !password) {
  console.error("FALTAN_CREDENCIALES");
  process.exit(1);
}

// 1) Listar usuarios con service role (solo datos no sensibles)
const listRes = await fetch(`${url}/auth/v1/admin/users?page=1&per_page=50`, {
  headers: { apikey: service, Authorization: `Bearer ${service}` },
});
const listJson = await listRes.json();
const users = listJson.users ?? [];
console.log("TOTAL_USERS=" + users.length);
users.forEach((u, i) => {
  const e = u.email ?? "";
  const domain = e.includes("@") ? "@" + e.split("@")[1].split(".")[0] : "";
  const masked = e.slice(0, 3) + "***" + domain;
  console.log(
    `USER[${i}] id=${u.id} email=${masked} created=${u.created_at} last_sign_in=${u.last_sign_in_at ?? "never"} confirmed=${u.email_confirmed_at ? "yes" : "no"}`,
  );
});

// 2) Login con el usuario elegido
const idx = Number(process.argv[2] ?? "1");
const user = users[idx];
if (!user) {
  console.error("NO_USER_AT_INDEX=" + idx);
  process.exit(1);
}
const email = user.email;
console.log("TARGET_INDEX=" + idx + " user_id=" + user.id);

const makeStore = () => {
  const store = [];
  return {
    store,
    methods: {
      getAll: () => [...store],
      setAll: (cookies) => {
        for (const c of cookies) {
          const i = store.findIndex((s) => s.name === c.name);
          if (i >= 0) store[i] = c;
          else store.push(c);
        }
      },
    },
  };
};

const trySignIn = () => {
  const { store, methods } = makeStore();
  const sb = createServerClient(url, anon, { cookies: methods });
  return sb.auth
    .signInWithPassword({ email, password })
    .then((r) => ({ ...r, store }));
};

let attempt = await trySignIn();
if (attempt.error) {
  console.log("SIGNIN_FAIL=" + attempt.error.message);
  // Reset de password del usuario QA (cuenta de prueba en STAGING, autorizado)
  const upd = await fetch(`${url}/auth/v1/admin/users/${user.id}`, {
    method: "PUT",
    headers: { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json" },
    body: JSON.stringify({ password }),
  });
  console.log("PASSWORD_RESET_HTTP=" + upd.status);
  attempt = await trySignIn();
  if (attempt.error) {
    console.error("SIGNIN_FAIL_AFTER_RESET=" + attempt.error.message);
    process.exit(1);
  }
}
console.log("SIGNIN_OK user=" + attempt.data.user.id);

// 3) Escribir jar con TODAS las cookies que el cliente ssr habria sembrado
const jarPath = join(tmpdir(), "qa_cookie_jar_estampados.txt");
const jar = attempt.store.map((c) => `${c.name}=${c.value}`).join("\n");
writeFileSync(jarPath, jar, "utf8");
console.log("JAR_PATH=" + jarPath);
console.log("JAR_COOKIES=" + attempt.store.length);
for (const c of attempt.store) {
  console.log(`COOKIE name=${c.name} len=${c.value.length}`);
}
