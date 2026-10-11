# permutON — versión con Supabase

La app usa Supabase Auth, PostgreSQL y Storage. Las publicaciones y propuestas quedan disponibles entre dispositivos. No incluye pagos ni chat en esta etapa.

## Actualización: calificaciones y menú lateral

Ejecutá `migration-09-reviews.sql` una vez en SQL Editor después de migration-08, antes de reemplazar `dist/index.html` y `dist/app.js`. La última línea programa otra tarea automática con Cron (cada hora); si falla, ejecutala sola una vez que Cron esté activo.

- **Calificaciones:** al concretarse una permuta, las dos partes reciben "Calificá a…". Cada una califica a la otra una sola vez, de 1 a 5 estrellas con comentario opcional, desde Mis propuestas. La opinión se publica cuando califican las dos o a los 14 días de concretada (lo que pase primero); hasta entonces solo la ve quien la escribió. Recordatorio a los 3 días; pasados 14 días ya no se puede calificar.
- **Perfil público:** promedio de estrellas, cantidad de calificaciones y las últimas 10 opiniones.
- **Encabezado:** las opciones de cuenta (Mis publicaciones, Mis propuestas, Mi perfil, Salir, Ingresar) pasan a un menú lateral que se abre con el botón ☰ a la izquierda. En el encabezado quedan solo Avisos (campana con contador) y Publicar.

## Actualización: confirmación de permutas, avisos y vencimiento

Ejecutá `migration-08-trade-confirmation.sql` una vez en SQL Editor después de migration-07, **antes** de reemplazar `dist/index.html` y `dist/app.js` (sin la migración, el catálogo no carga). Las últimas dos líneas del archivo activan una tarea automática con Cron cada 15 minutos; si fallan, activá Cron en **Supabase > Integrations > Cron** y ejecutá solo esas dos líneas.

- **Confirmación:** al aceptar una propuesta, cada parte responde en Mis propuestas si la permuta se concretó. Se concreta solo si las dos confirman. Quien no respondió recibe avisos a los 2 y 3 días. A los 5 días sin las dos respuestas se cancela: si el dueño había respondido, su publicación vuelve al catálogo; si el dueño no respondió, queda vencida y debe renovarla. Quien no respondió suma una "permuta sin confirmar" en su perfil. Si alguien responde que no se concretó, se cancela y la publicación vuelve al catálogo.
- **Vencimiento:** cada publicación dura 2 semanas y se renueva desde Mis publicaciones. Hay aviso 2 días antes. Al vencer deja de verse en el catálogo y en el perfil público (el dueño la sigue viendo) y sus propuestas pendientes vencen con aviso a quien propuso. Las publicaciones existentes reciben 2 semanas desde que se ejecuta la migración. Ya no se puede marcar como intercambiado a mano.
- **Avisos:** botón Avisos con contador (se actualiza cada 30 segundos) para propuestas recibidas, aceptadas, rechazadas, canceladas, confirmaciones, recordatorios y vencimientos. Solo dentro de la app.
- Datos anteriores: las propuestas aceptadas de publicaciones ya marcadas como intercambiadas se dan por concretadas; las aceptadas en curso arrancan sus 5 días al ejecutar la migración.

## Actualización: perfil público

Ejecutá `migration-07-public-profile.sql` una vez en SQL Editor después de migration-06, antes de reemplazar `dist/index.html` y `dist/app.js`.

Tocando el nombre de quien publica (en el catálogo o el detalle) o de quien envía una propuesta se abre su perfil público: foto, bio, ubicación, antigüedad, última actividad (solo el día), publicaciones disponibles e historial de reservadas/permutadas. Muestra permutas acordadas, publicaciones disponibles, porcentaje de propuestas respondidas y tiempo de respuesta promedio; esas cifras las calcula la función `get_profile_stats` en la base, sin exponer propuestas ni mensajes. Las publicaciones reservadas e intercambiadas pasan a ser visibles para todos (el catálogo sigue mostrando solo las activas).

## Actualización: perfiles de usuario

Ejecutá `migration-06-profiles.sql` una vez en SQL Editor después de migration-05, **antes** de reemplazar `dist/index.html` y `dist/app.js` (conservá `config.js`).

Cada cuenta tiene un perfil con nombre visible, bio, ubicación y foto opcionales, editable desde **Mi perfil**. El registro pide el nombre visible. Los usuarios existentes reciben un perfil con el último nombre que usaron al publicar o proponer. El nombre de publicaciones y propuestas lo asigna la base a partir del perfil (ya no se escribe en cada formulario) y se actualiza en todas ellas al cambiarlo. El perfil no muestra email ni contacto. La foto de perfil se guarda en el mismo bucket de fotos, dentro de la carpeta del usuario.

## Actualización: diseño responsive

Reemplazá `dist/index.html` y conservá los demás archivos y config.js. No requiere SQL. Se ajustaron encabezado, filtros, catálogo, controles y ventanas para celular, tablet y escritorio. En celulares de hasta 540 px las ventanas ocupan la pantalla; en tablet/escritorio tienen altura limitada y scroll. Se aumentaron controles táctiles y tamaños de campos para evitar zoom involuntario en móviles.

## Actualización: Argentina y aceptación

Ejecutá `migration-05-argentina-accepted.sql` una vez en SQL Editor después de migration-04. Contiene el catálogo de 4028 localidades de GeoRef (Argentina, descarga 2026-10-05). Reemplazá `dist/index.html`, `dist/app.js` y agregá `dist/locations.js`; conservá `config.js`. No requiere otros servicios ni consulta la API de GeoRef desde el navegador.

Las nuevas publicaciones exigen provincia y localidad; las existentes conservan sus datos y se completan al editarlas. El catálogo permite filtrar por provincia/localidad y muestra los últimos 100 artículos cargados.

Aceptar una propuesta retira el artículo del catálogo con el estado `reserved` (Permuta aceptada), rechaza las demás propuestas pendientes y mantiene el chat aceptado. La operación se hace en una transacción y bloquea la publicación para evitar aceptaciones simultáneas. Las propuestas aceptadas previamente también retiran sus publicaciones activas. El dueño sigue viéndolas en Mis publicaciones y puede marcar el intercambio como concretado. Una publicación con una propuesta aceptada no puede reactivarse. El catálogo abierto se consulta cada 15 segundos; el chat cada 5 segundos.

## Actualización: Chat

Ejecutá `migration-04-chat.sql` una vez en SQL Editor, después de migration-03. Reemplazá `dist/index.html` y `dist/app.js`, conservando `config.js`. En Mis propuestas aparece Abrir chat. Solo las dos partes acceden a los mensajes. Se puede escribir en propuestas pendientes o aceptadas; las rechazadas/canceladas permiten leer el historial. El chat recarga cada 5 segundos mientras está abierto y muestra los 100 mensajes más recientes. No incluye adjuntos ni notificaciones fuera del chat. Eliminar la publicación elimina también sus propuestas y mensajes.

## Actualización: Mis propuestas

Ejecutá `migration-03-offer-status.sql` una vez en SQL Editor (después de migration-02). Después reemplazá `dist/index.html` y `dist/app.js` conservando `config.js`. Las propuestas existentes comienzan como pendientes. En Mis propuestas se separan enviadas y recibidas: el dueño puede aceptar o rechazar; el remitente puede cancelar, solo mientras estén pendientes. Las acciones se validan en Supabase mediante funciones y actualizaciones bloqueadas para evitar cambios concurrentes.

Aceptar una propuesta ahora retira el artículo del catálogo como Permuta aceptada; marcá Intercambiado desde Mis publicaciones cuando se concrete. Actualizar recarga los estados; no hay actualización en tiempo real en esta etapa.

## Actualización: Mis publicaciones

Si ya ejecutaste migration-02, esta actualización no requiere SQL adicional. Reemplazá `dist/index.html` y `dist/app.js`, conservá tu `dist/config.js` y recargá la página. Las políticas existentes permiten administrar únicamente publicaciones propias.

## Actualizar una instalación que ya funciona

1. En **Supabase > SQL Editor**, ejecutá **solo** `migration-02-multiple-images.sql`. Conserva publicaciones, fotos y propuestas anteriores. No repitas `schema.sql`.
2. Reemplazá los archivos de la web por los nuevos. Si ya pusiste tu URL y clave en `dist/config.js`, **conservá tu propio config.js**; el ZIP incluye un archivo de ejemplo con valores vacíos.
3. Reiniciá el servidor local y recargá la página. Probá una publicación y una oferta con dos fotos.

La migración debe ejecutarse antes de usar la nueva página.

## 1. Crear el proyecto de Supabase

1. Creá un proyecto en https://supabase.com/dashboard.
2. Abrí **SQL Editor** y ejecutá primero `schema.sql` y después `migration-02-multiple-images.sql`, una vez cada uno; luego ejecutá `migration-03-offer-status.sql` , `migration-04-chat.sql` y `migration-05-argentina-accepted.sql`. Estos archivos crean tablas, índices, permisos y el bucket público para fotos.
3. En **Project Settings > API** (o **Connect**), copiá la **Project URL** y la **publishable key**. La clave `anon` también sirve si tu proyecto todavía utiliza ese formato. Nunca uses `service_role` ni una secret key en el navegador.
4. Editá `dist/config.js` con esos dos valores. `dist/config.example.js` queda como referencia.
5. En **Authentication > URL Configuration**, configurá como **Site URL** la URL desde la que vas a abrir la web. Para la prueba local con el comando de abajo: `http://localhost:8000`. Si luego cambiás de dominio, agregalo también a las URL de redirección autorizadas.
6. En **Authentication > Providers > Email**, verificá que el proveedor esté habilitado. Con confirmación por email activada, la persona debe confirmar el correo antes de ingresar. Tené presente el límite de correos del servicio gratuito; para un lanzamiento real conviene configurar SMTP propio.

## 2. Abrir en VS Code

Abrí la carpeta `permuton` y ejecutá en la terminal:

```bash
python -m http.server 8000 --directory dist
```

Abrí `http://localhost:8000`. También podés usar Live Server, ajustando la Site URL al puerto que utilice.

## Qué hace

- Registro y acceso con email y contraseña.
- Publicaciones compartidas, cada una con 1 a 5 fotos obligatorias, tiempo de tenencia y motivo.
- Búsqueda y filtro por categoría (hasta 100 artículos recientes; para crecer se implementará paginación y búsqueda en servidor).
- Propuestas persistentes con 1 a 5 fotos y detalles del objeto ofrecido (título, categoría, descripción, tiempo de tenencia y motivo). El dueño ve las recibidas en **Propuestas** y el contacto solo es visible para las dos partes mediante las políticas de acceso. Las propuestas anteriores siguen visibles sin fotos ni nuevos campos.
- Fotos comprimidas en el navegador y almacenadas en Storage; PostgreSQL guarda hasta cinco rutas por artículo o propuesta.

## Limitaciones de esta etapa

- Hay chat de texto por propuesta; todavía no hay notificaciones fuera del chat.
- **Mis publicaciones** permite editar datos, reemplazar todas las fotos, eliminar y marcar como intercambiado o volver a publicar. Eliminar también borra las propuestas asociadas. Las fotos de la publicación se borran después de eliminarla; las fotos que otros usuarios subieron en propuestas no se borran automáticamente.
- Las publicaciones antiguas guardadas por la versión anterior en `localStorage` no se migran automáticamente; deberán publicarse nuevamente.
- El bucket de fotos es público porque los artículos son públicos: no subas imágenes privadas ni datos sensibles.
- La clave publicable del proyecto puede aparecer en el código del navegador; las reglas RLS de `schema.sql` son las que protegen las operaciones.
- Si se vuelve a ejecutar `schema.sql` completo, las políticas existentes producirán error: es un script de instalación inicial, no una migración repetible.

Fuente de provincias/localidades: https://www.argentina.gob.ar/georef y https://apis.datos.gob.ar/georef/api/v2.0/localidades. En CABA el catálogo de localidades identifica barrios.
