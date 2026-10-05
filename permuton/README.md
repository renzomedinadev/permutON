# permutON — versión con Supabase

La app usa Supabase Auth, PostgreSQL y Storage. Las publicaciones y propuestas quedan disponibles entre dispositivos. No incluye pagos ni chat en esta etapa.

## Actualizar una instalación que ya funciona

1. En **Supabase > SQL Editor**, ejecutá **solo** `migration-02-multiple-images.sql`. Conserva publicaciones, fotos y propuestas anteriores. No repitas `schema.sql`.
2. Reemplazá los archivos de la web por los nuevos. Si ya pusiste tu URL y clave en `dist/config.js`, **conservá tu propio config.js**; el ZIP incluye un archivo de ejemplo con valores vacíos.
3. Reiniciá el servidor local y recargá la página. Probá una publicación y una oferta con dos fotos.

La migración debe ejecutarse antes de usar la nueva página.

## 1. Crear el proyecto de Supabase

1. Creá un proyecto en https://supabase.com/dashboard.
2. Abrí **SQL Editor** y ejecutá primero `schema.sql` y después `migration-02-multiple-images.sql`, una vez cada uno. Estos archivos crean tablas, índices, permisos y el bucket público para fotos.
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

- No hay chat ni notificaciones: el dueño debe entrar en **Propuestas** y contactar al interesado.
- No hay panel para editar, eliminar o marcar como intercambiado. Las políticas de la base ya contemplan editar y eliminar publicaciones propias.
- Las publicaciones antiguas guardadas por la versión anterior en `localStorage` no se migran automáticamente; deberán publicarse nuevamente.
- El bucket de fotos es público porque los artículos son públicos: no subas imágenes privadas ni datos sensibles.
- La clave publicable del proyecto puede aparecer en el código del navegador; las reglas RLS de `schema.sql` son las que protegen las operaciones.
- Si se vuelve a ejecutar `schema.sql` completo, las políticas existentes producirán error: es un script de instalación inicial, no una migración repetible.
