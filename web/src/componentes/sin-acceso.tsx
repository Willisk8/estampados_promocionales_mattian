/**
 * Pantalla para una sesion valida sin perfil de consola.
 *
 * Es un caso legitimo, no un fallo: sin fila activa en perfil_usuario, RLS no
 * devuelve nada. Mostrarlo asi evita que se confunda con una base vacia o con
 * una consulta rota, que es exactamente la confusion que se quiere evitar.
 */
export function SinAcceso() {
  return (
    <div className="centro">
      <h1>Sin acceso a la consola</h1>
      <p className="subtitulo">
        Tu sesion es valida, pero no tienes un perfil activo. Las politicas de la
        base no devuelven ningun dato hasta que exista uno.
      </p>
      <div className="aviso-caja neutro">
        Un administrador debe crear tu perfil ejecutando, con <code>psql</code>:
        <br />
        <br />
        <code>
          INSERT INTO perfil_usuario (user_id, email, rol) VALUES (&#39;&lt;uuid de
          auth.users&gt;&#39;, &#39;&lt;tu correo&gt;&#39;, &#39;LECTURA&#39;);
        </code>
      </div>
      <form action="/auth/salir" method="post">
        <button type="submit">Cerrar sesion</button>
      </form>
    </div>
  );
}
