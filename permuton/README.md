# permutON — versión con Supabase

La app usa Supabase Auth, PostgreSQL y Storage. Las publicaciones y propuestas quedan disponibles entre dispositivos. No incluye pagos ni chat en esta etapa.

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
python3 -m http.server 8000 --directory dist
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
