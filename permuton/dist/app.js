const $ = id => document.getElementById(id);
const cfg = window.PERMUTON_CONFIG || {};
const configured = /^https:\/\/.+\.supabase\.co$/.test(cfg.supabaseUrl || '') && cfg.supabasePublishableKey && !cfg.supabasePublishableKey.startsWith('TU_');
const db = configured && window.supabase?.createClient(cfg.supabaseUrl, cfg.supabasePublishableKey);
let currentUser = null;
let myProfile = null;
let items = [];
let authMode = 'login';
const previewUrls = new Map();

function message(text) { $('appMessage').textContent = text; $('appMessage').hidden = !text; }
function displayError(error) { return error?.message || 'Ocurrió un error. Intentá nuevamente.'; }
const localityCatalog = window.AR_LOCALITIES || [];
const localityMap = new Map(localityCatalog.map(l => [l.id, l]));
const provinceMap = new Map(localityCatalog.map(l => [l.provinceId, l.province]));
function locationText(item) { const l = localityMap.get(item.locality_id); return l ? `${l.name}, ${l.province}` : 'Ubicación pendiente'; }
function fillProvinces(select, blank) {
  select.replaceChildren(new Option(blank, ''));
  [...provinceMap.entries()].sort((a, b) => a[1].localeCompare(b[1], 'es')).forEach(([id, name]) => select.append(new Option(name, id)));
}
function fillLocalities(select, province, blank) {
  select.replaceChildren(new Option(blank, '')); select.disabled = !province;
  const list = localityCatalog.filter(l => l.provinceId === province).sort((a, b) => a.name.localeCompare(b.name, 'es'));
  const counts = new Map(); list.forEach(l => counts.set(l.name, (counts.get(l.name) || 0) + 1));
  list.forEach(l => select.append(new Option(l.name + (counts.get(l.name) > 1 ? ` (${l.department || l.id})` : ''), l.id)));
}
function locationFields(item = {}) {
  const provinceLabel = document.createElement('label'); provinceLabel.textContent = 'Provincia';
  const province = document.createElement('select'); province.name = 'province'; province.required = true; fillProvinces(province, 'Seleccionar provincia'); province.value = item.province_id || '';
  const localityLabel = document.createElement('label'); localityLabel.textContent = 'Localidad';
  const locality = document.createElement('select'); locality.name = 'locality'; locality.required = true; fillLocalities(locality, province.value, 'Seleccionar localidad'); locality.value = item.locality_id || '';
  province.addEventListener('change', () => fillLocalities(locality, province.value, 'Seleccionar localidad'));
  provinceLabel.append(province); localityLabel.append(locality); return [provinceLabel, localityLabel];
}
function locationValues(form) {
  const province = form.elements.namedItem('province').value; const locality = form.elements.namedItem('locality').value;
  if (!localityMap.has(locality) || localityMap.get(locality).provinceId !== province) throw Error('Seleccioná una provincia y localidad válidas de Argentina.');
  return { province_id: province, locality_id: locality };
}
const publicationLocation = document.createElement('div'); publicationLocation.className = 'form'; publicationLocation.append(...locationFields());
$('publishForm').insertBefore(publicationLocation, $('publishForm').querySelector('[name="description"]').parentElement);
fillProvinces($('provinceFilter'), 'Todas las provincias'); fillLocalities($('localityFilter'), '', 'Todas las localidades');
$('provinceFilter').addEventListener('change', () => { fillLocalities($('localityFilter'), $('provinceFilter').value, 'Todas las localidades'); render(); });
$('localityFilter').addEventListener('change', render);

function photoUrl(path) { return db.storage.from('publication-photos').getPublicUrl(path).data.publicUrl; }
function pathsFor(record) { return record.photo_paths?.length ? record.photo_paths : (record.photo_path ? [record.photo_path] : []); }
function imageFor(item) {
  const art = document.createElement('div'); art.className = 'art';
  const img = document.createElement('img'); img.src = photoUrl(pathsFor(item)[0]); img.alt = 'Foto de ' + item.title; img.loading = 'lazy';
  art.append(img); return art;
}
function gallery(paths, title) {
  const wrap = document.createElement('div');
  if (!paths.length) return wrap;
  const main = document.createElement('div'); main.className = 'gallery-main';
  const img = document.createElement('img'); img.alt = 'Foto 1 de ' + paths.length + ': ' + title; main.append(img);
  const counter = document.createElement('p'); counter.className = 'gallery-counter';
  const thumbs = document.createElement('div'); thumbs.className = 'gallery-thumbs';
  const buttons = paths.map((path, i) => {
    const button = document.createElement('button'); button.type = 'button'; button.setAttribute('aria-label', 'Ver foto ' + (i + 1) + ' de ' + paths.length);
    const thumb = document.createElement('img'); thumb.src = photoUrl(path); thumb.alt = ''; thumb.loading = 'lazy'; button.append(thumb);
    button.addEventListener('click', () => select(i)); thumbs.append(button); return button;
  });
  function select(index) {
    img.src = photoUrl(paths[index]); img.alt = 'Foto ' + (index + 1) + ' de ' + paths.length + ': ' + title;
    counter.textContent = 'Foto ' + (index + 1) + ' de ' + paths.length;
    buttons.forEach((button, i) => button.setAttribute('aria-current', String(i === index)));
  }
  select(0); wrap.append(main, counter, thumbs); return wrap;
}
function detailLine(label, value) {
  const p = document.createElement('p'); const b = document.createElement('strong'); b.textContent = label;
  p.append(b, document.createTextNode(value || 'Sin especificar')); return p;
}
const publicationStatusLabels = { active: 'Disponible', reserved: 'Permuta en curso', exchanged: 'Permutada' };
function ownerLink(name, userId) {
  const button = document.createElement('button'); button.type = 'button'; button.className = 'owner-link'; button.textContent = name || 'Usuario';
  button.setAttribute('aria-label', 'Ver perfil de ' + (name || 'usuario'));
  button.addEventListener('click', e => { e.stopPropagation(); if ($('detailDialog').open) $('detailDialog').close(); openPublicProfile(userId); });
  return button;
}
function updateAccount() {
  const signed = !!currentUser; if (myProfile?.id !== currentUser?.id) myProfile = null;
  $('accountLabel').textContent = signed ? (myProfile?.display_name || currentUser.email) : '';
  $('authBtn').hidden = signed; $('logoutBtn').hidden = !signed; $('offersBtn').hidden = !signed; $('myPublicationsBtn').hidden = !signed; $('profileBtn').hidden = !signed; $('notificationsBtn').hidden = !signed;
  if (signed) { loadMyProfile(); loadNotificationCount(); }
  if (!signed) { stopChat(); if ($('chatDialog').open) $('chatDialog').close(); $('chatMessages').replaceChildren(); offerEntries = []; for (const id of ['myPublicationsDialog', 'editPublicationDialog', 'offersDialog', 'publishDialog', 'detailDialog', 'profileDialog', 'notificationsDialog']) { if ($(id).open) $(id).close(); } $('myPublicationsList').replaceChildren(); $('offersList').replaceChildren(); $('profileContent').replaceChildren(); $('notificationsList').replaceChildren(); $('notificationsBtn').textContent = 'Avisos'; }
}
async function loadMyProfile() {
  if (!currentUser) return null;
  const userId = currentUser.id;
  const { data, error } = await db.from('profiles').select('*').eq('id', userId).maybeSingle();
  if (currentUser?.id !== userId) return null;
  if (error) { message('No pudimos cargar tu perfil: ' + displayError(error)); return null; }
  myProfile = data; $('accountLabel').textContent = myProfile?.display_name || currentUser.email;
  return myProfile;
}
async function loadItems() {
  if (!db) return;
  message('');
  const { data, error } = await db.from('publications').select('*').eq('status', 'active').gt('expires_at', new Date().toISOString()).order('created_at', { ascending: false }).limit(100);
  if (error) { message('No pudimos cargar las publicaciones: ' + displayError(error)); return; }
  items = data || []; render();
}
function render() {
  const q = $('search').value.trim().toLocaleLowerCase('es'); const category = $('category').value;
  const filtered = items.filter(x => (!category || x.category === category) && (!$('provinceFilter').value || x.province_id === $('provinceFilter').value) && (!$('localityFilter').value || x.locality_id === $('localityFilter').value) && (!q || [x.title, x.description, x.wanted].some(v => v.toLocaleLowerCase('es').includes(q))));
  const grid = $('grid'); grid.replaceChildren();
  if (!filtered.length) {
    const p = document.createElement('p'); p.className = 'empty'; p.textContent = items.length ? 'No encontramos artículos con esos filtros.' : 'Todavía no hay artículos publicados. ¡Publicá el primero!'; grid.append(p); return;
  }
  for (const item of filtered) {
    const card = document.createElement('article'); card.className = 'card'; const body = document.createElement('div'); body.className = 'card-body';
    const meta = document.createElement('div'); meta.className = 'meta'; meta.append(item.category + ' · ', ownerLink(item.owner_name, item.owner_id), ' · ' + locationText(item));
    const title = document.createElement('h3'); title.textContent = item.title;
    const wanted = document.createElement('p'); wanted.textContent = 'Busca: ' + item.wanted;
    const button = document.createElement('button'); button.textContent = 'Ver y proponer permuta'; button.addEventListener('click', () => openDetail(item));
    body.append(meta, title, wanted, button); card.append(imageFor(item), body); grid.append(card);
  }
}
function categorySelect(name) {
  const label = document.createElement('label'); label.textContent = 'Categoría';
  const select = document.createElement('select'); select.name = name; select.required = true;
  for (const value of ['', 'Indumentaria', 'Tecnología', 'Hogar', 'Deportes', 'Libros', 'Otros']) {
    const option = document.createElement('option'); option.value = value; option.textContent = value || 'Seleccionar'; select.append(option);
  }
  label.append(select); return label;
}
function field(labelText, name, type, max, placeholder) {
  const label = document.createElement('label'); label.textContent = labelText;
  const input = type === 'textarea' ? document.createElement('textarea') : document.createElement('input');
  if (type !== 'textarea') input.type = type;
  input.name = name; input.required = true; input.maxLength = max; input.placeholder = placeholder || '';
  label.append(input); return label;
}
function photoField(id, previewId) {
  const label = document.createElement('label'); label.textContent = 'Fotos reales del objeto que ofrecés (1 a 5)';
  const input = document.createElement('input'); input.type = 'file'; input.name = 'photos'; input.id = id; input.accept = 'image/jpeg,image/png,image/webp'; input.multiple = true; input.required = true;
  const hint = document.createElement('span'); hint.className = 'hint'; hint.textContent = 'JPG, PNG o WebP · hasta 8 MB por foto. La primera será la portada.';
  const preview = document.createElement('div'); preview.id = previewId; preview.className = 'preview-grid'; preview.setAttribute('aria-live', 'polite');
  label.append(input, hint); input.addEventListener('change', () => previewFiles(input, preview));
  return [label, preview];
}
function openDetail(item) {
  const box = $('detailContent'); box.replaceChildren();
  const title = document.createElement('h2'); title.textContent = item.title;
  const meta = document.createElement('p'); meta.append(item.category + ' · Publicado por ', ownerLink(item.owner_name, item.owner_id));
  const desc = document.createElement('p'); desc.textContent = item.description;
  box.append(title, meta, gallery(pathsFor(item), item.title), detailLine('Ubicación: ', locationText(item)), desc, detailLine('Lo tiene desde: ', item.owned_time), detailLine('Motivo de publicación: ', item.reason), detailLine('Busca a cambio: ', item.wanted));
  if (currentUser?.id === item.owner_id) {
    const own = document.createElement('p'); own.className = 'success'; own.textContent = 'Esta es tu publicación. Las propuestas recibidas están en el botón Propuestas.'; box.append(own);
  } else if (item.status !== 'active') {
    const closed = document.createElement('p'); closed.className = 'success'; closed.textContent = 'Este artículo ya no está disponible para permutar (' + (publicationStatusLabels[item.status] || item.status).toLowerCase() + ').'; box.append(closed);
  } else {
    const form = document.createElement('form'); form.className = 'form';
    const heading = document.createElement('h3'); heading.textContent = 'Ofrecer una permuta';
    const [photos, preview] = photoField('offerPhotos', 'offerPreviews');
    const errorBox = document.createElement('p'); errorBox.className = 'error'; errorBox.setAttribute('role', 'alert'); errorBox.hidden = true;
    const button = document.createElement('button'); button.type = 'submit'; button.className = 'primary'; button.textContent = 'Enviar propuesta';
    form.append(heading, field('Título del objeto', 'title', 'text', 70, 'Ej. Campera talle L'), categorySelect('category'), field('Descripción y estado', 'description', 'textarea', 500), photos, preview, field('¿Hace cuánto lo tenés?', 'ownedTime', 'text', 80, 'Ej. Hace 2 años'), field('¿Por qué lo ofrecés?', 'reason', 'textarea', 300), field('Tu contacto (email o teléfono)', 'contact', 'text', 100, 'Visible solo para quien publicó'), errorBox, button);
    form.addEventListener('submit', e => submitOffer(e, item, form, button, errorBox)); box.append(form);
  }
  $('detailDialog').showModal();
}
function validateFiles(input) {
  const files = Array.from(input.files || []);
  if (files.length < 1 || files.length > 5) throw Error('Elegí entre 1 y 5 fotos.');
  if (files.some(file => !['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 8 * 1024 * 1024)) throw Error('Cada foto debe ser JPG, PNG o WebP y pesar hasta 8 MB.');
  return files;
}
function clearPreview(container) {
  const urls = previewUrls.get(container) || [];
  urls.forEach(url => URL.revokeObjectURL(url)); previewUrls.delete(container); container.replaceChildren();
}
function previewFiles(input, container) {
  clearPreview(container);
  try {
    const files = validateFiles(input); const urls = files.map(file => URL.createObjectURL(file)); previewUrls.set(container, urls);
    urls.forEach((url, i) => { const img = document.createElement('img'); img.src = url; img.alt = 'Foto seleccionada ' + (i + 1); container.append(img); });
  } catch (error) { input.value = ''; const p = document.createElement('p'); p.className = 'error'; p.textContent = displayError(error); container.append(p); }
}
async function compressPhoto(file, maxSide = 1000) {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image(); img.src = url; await img.decode();
    const scale = Math.min(1, maxSide / Math.max(img.naturalWidth, img.naturalHeight)); const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale)); canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
    canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
    return await new Promise((resolve, reject) => canvas.toBlob(blob => blob ? resolve(blob) : reject(Error('No pudimos procesar la foto.')), 'image/jpeg', .72));
  } finally { URL.revokeObjectURL(url); }
}
async function uploadPhotos(files) {
  const uploaded = [];
  try {
    for (const file of files) {
      const blob = await compressPhoto(file); const path = `${currentUser.id}/${crypto.randomUUID()}.jpg`;
      const { error } = await db.storage.from('publication-photos').upload(path, blob, { contentType: 'image/jpeg', upsert: false });
      if (error) throw error;
      uploaded.push(path);
    }
    return uploaded;
  } catch (error) { await removePhotos(uploaded); throw error; }
}
async function removePhotos(paths) { if (paths.length) await db.storage.from('publication-photos').remove(paths); }
async function submitOffer(e, item, form, button, errorBox) {
  e.preventDefault(); errorBox.hidden = true;
  if (!currentUser) { $('detailDialog').close(); openAuth(); return; }
  let uploaded = []; button.disabled = true; button.textContent = 'Enviando...';
  try {
    const files = validateFiles(form.querySelector('input[type="file"]')); const d = new FormData(form);
    uploaded = await uploadPhotos(files);
    const row = { publication_id: item.id, sender_id: currentUser.id, title: String(d.get('title')).trim(), category: String(d.get('category')), description: String(d.get('description')).trim(), offered_item: String(d.get('description')).trim(), owned_time: String(d.get('ownedTime')).trim(), reason: String(d.get('reason')).trim(), contact: String(d.get('contact')).trim(), photo_paths: uploaded };
    const { error } = await db.from('offers').insert(row); if (error) throw error;
    clearPreview(form.querySelector('.preview-grid'));
    const success = document.createElement('p'); success.className = 'success'; success.textContent = 'Propuesta enviada. El dueño podrá ver las fotos y los detalles en Propuestas.'; form.replaceWith(success);
  } catch (error) { await removePhotos(uploaded); errorBox.textContent = displayError(error); errorBox.hidden = false; }
  finally { button.disabled = false; button.textContent = 'Enviar propuesta'; }
}
function openAuth() { if (!db) { message('Configurá Supabase en config.js para activar las cuentas y publicaciones.'); return; } $('authDialog').showModal(); }
function showAuthMode() {
  const signup = authMode === 'signup'; $('authNameField').hidden = !signup; $('authForm').elements.namedItem('displayName').required = signup; $('authTitle').textContent = signup ? 'Crear cuenta' : 'Ingresar'; $('authSubmit').textContent = signup ? 'Crear cuenta' : 'Ingresar'; $('authToggle').textContent = signup ? 'Ya tengo cuenta' : 'Crear una cuenta'; $('authError').hidden = true;
}
$('authToggle').addEventListener('click', () => { authMode = authMode === 'login' ? 'signup' : 'login'; showAuthMode(); });
$('authForm').addEventListener('submit', async e => {
  e.preventDefault(); const authForm = e.currentTarget; const d = new FormData(authForm); const email = String(d.get('email')).trim(); const password = String(d.get('password')); const button = $('authSubmit'); button.disabled = true; $('authError').hidden = true;
  try {
    const displayName = String(d.get('displayName') || '').trim();
    const { data, error } = authMode === 'signup' ? await db.auth.signUp({ email, password, options: { data: { display_name: displayName } } }) : await db.auth.signInWithPassword({ email, password });
    if (error) throw error;
    if (authMode === 'signup' && !data.session) { authMode = 'login'; showAuthMode(); $('authError').textContent = 'Revisá tu email para confirmar la cuenta. Después ingresá.'; $('authError').className = 'success'; $('authError').hidden = false; return; }
    $('authDialog').close(); authForm.reset();
  } catch (error) { $('authError').className = 'error'; $('authError').textContent = displayError(error); $('authError').hidden = false; }
  finally { button.disabled = false; }
});
$('authBtn').addEventListener('click', openAuth);
$('logoutBtn').addEventListener('click', async () => { const { error } = await db.auth.signOut(); if (error) message(displayError(error)); });
$('publishBtn').addEventListener('click', () => currentUser ? $('publishDialog').showModal() : openAuth());
let offerDirection = 'received';
let offerEntries = [];
const statusLabels = { pending: 'Pendiente', accepted: 'Aceptada · Esperando confirmación', rejected: 'Rechazada', cancelled: 'Cancelada', completed: 'Permuta concretada', failed: 'No se concretó', abandoned: 'Cancelada por falta de respuesta', expired: 'Vencida' };
function shortDate(value) { return new Date(value).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }); }
function tradeBox(entry) {
  const offer = entry.offer; const mine = entry.direction === 'received' ? offer.owner_response : offer.sender_response;
  const theirs = entry.direction === 'received' ? offer.sender_response : offer.owner_response;
  const box = document.createElement('div'); box.className = 'trade-box';
  const deadline = new Date(new Date(offer.accepted_at).getTime() + 5 * 86400000);
  const info = document.createElement('p');
  const errorBox = document.createElement('p'); errorBox.className = 'error'; errorBox.hidden = true; errorBox.setAttribute('role', 'alert');
  if (mine) {
    info.textContent = 'Ya respondiste que ' + (mine === 'confirmed' ? 'se concretó' : 'no se concretó') + '. Esperando a la otra parte (plazo: ' + shortDate(deadline) + ').';
    box.append(info); return box;
  }
  info.textContent = (theirs === 'confirmed' ? 'La otra parte ya confirmó. ' : '') + '¿Se concretó la permuta? Respondé antes del ' + shortDate(deadline) + '. Solo se concreta si las dos partes confirman.';
  const actions = document.createElement('div'); actions.className = 'manage-actions';
  for (const [label, result] of [['Sí, se concretó', 'confirmed'], ['No se concretó', 'failed']]) {
    const button = document.createElement('button'); button.type = 'button'; button.textContent = label;
    button.addEventListener('click', async () => {
      if (!currentUser) return;
      if (!confirm(result === 'confirmed' ? '¿Confirmás que la permuta se concretó? No se puede cambiar después.' : '¿Confirmás que la permuta NO se concretó? Se cancelará y la publicación volverá al catálogo.')) return;
      actions.querySelectorAll('button').forEach(b => b.disabled = true); errorBox.hidden = true;
      try {
        const { error } = await db.rpc('respond_trade', { offer_id: offer.id, result }); if (error) throw error;
        await loadItems(); await loadMyOffers(); loadNotificationCount();
      } catch (error) { errorBox.textContent = displayError(error); errorBox.hidden = false; actions.querySelectorAll('button').forEach(b => b.disabled = false); }
    });
    actions.append(button);
  }
  box.append(info, actions, errorBox); return box;
}
async function loadMyOffers() {
  if (!currentUser) return;
  const userId = currentUser.id; const box = $('offersList'); box.textContent = 'Cargando...';
  if (!$('offersDialog').open) $('offersDialog').showModal();
  const { data, error } = await db.rpc('list_my_offers');
  if (currentUser?.id !== userId) return;
  if (error) { box.textContent = displayError(error); return; }
  offerEntries = data || []; renderMyOffers();
}
function renderMyOffers() {
  const box = $('offersList'); box.replaceChildren();
  $('receivedOffersBtn').setAttribute('aria-pressed', String(offerDirection === 'received'));
  $('sentOffersBtn').setAttribute('aria-pressed', String(offerDirection === 'sent'));
  const filtered = offerEntries.filter(entry => entry.direction === offerDirection);
  if (!filtered.length) { box.textContent = offerDirection === 'received' ? 'Todavía no recibiste propuestas.' : 'Todavía no enviaste propuestas.'; return; }
  for (const entry of filtered) {
    const offer = entry.offer;
    const row = document.createElement('article'); row.className = 'offer-row';
    const h = document.createElement('h3'); h.textContent = offer.title || 'Propuesta de permuta';
    row.append(detailLine('Publicación: ', entry.publication_title), detailLine('Estado: ', statusLabels[offer.status] || offer.status), h);
    if (offer.photo_paths?.length) row.append(gallery(offer.photo_paths, offer.title || 'Objeto ofrecido'));
    const from = document.createElement('p'); const fromLabel = document.createElement('strong'); fromLabel.textContent = 'De: '; from.append(fromLabel, ownerLink(offer.sender_name, offer.sender_id));
    row.append(from,detailLine('Categoría: ', offer.category), detailLine('Descripción: ', offer.description || offer.offered_item), detailLine('Lo tiene desde: ', offer.owned_time), detailLine('Motivo de la permuta: ', offer.reason), detailLine('Contacto del oferente: ', offer.contact));
    if (offer.status === 'pending') {
      const actions = document.createElement('div'); actions.className = 'manage-actions';
      const errorBox = document.createElement('p'); errorBox.className = 'error'; errorBox.hidden = true; errorBox.setAttribute('role', 'alert');
      const choices = offerDirection === 'received' ? [['Aceptar', 'accepted'], ['Rechazar', 'rejected']] : [['Cancelar propuesta', 'cancelled']];
      for (const [label, status] of choices) {
        const button = document.createElement('button'); button.textContent = label;
        button.addEventListener('click', async () => {
          if (!currentUser) return;
          if (!confirm(status === 'accepted' ? '¿Aceptar esta permuta? El artículo saldrá del catálogo y las demás propuestas pendientes se rechazarán.' : `¿${label} esta propuesta?`)) return;
          actions.querySelectorAll('button').forEach(b => b.disabled = true); errorBox.hidden = true;
          try {
            const { error } = await db.rpc('change_offer_status', { offer_id: offer.id, new_status: status });
            if (error) throw error;
            await loadItems(); await loadMyOffers();
          } catch (error) { errorBox.textContent = displayError(error); errorBox.hidden = false; actions.querySelectorAll('button').forEach(b => b.disabled = false); }
        });
        actions.append(button);
      }
      row.append(actions, errorBox);
    }
    if (offer.status === 'accepted') row.append(tradeBox(entry));
    const chatButton = document.createElement('button'); chatButton.type = 'button'; chatButton.className = 'primary'; chatButton.textContent = 'Abrir chat'; chatButton.addEventListener('click', () => openOfferChat(entry)); row.append(chatButton);
    box.append(row);
  }
}
$('offersBtn').addEventListener('click', loadMyOffers);
$('receivedOffersBtn').addEventListener('click', () => { offerDirection = 'received'; renderMyOffers(); });
$('sentOffersBtn').addEventListener('click', () => { offerDirection = 'sent'; renderMyOffers(); });
$('refreshOffersBtn').addEventListener('click', loadMyOffers);
$('search').addEventListener('input', render); $('category').addEventListener('change', render);
document.querySelectorAll('[data-close]').forEach(button => button.addEventListener('click', () => $(button.dataset.close).close()));
$('photos').addEventListener('change', () => { $('publishError').hidden = true; previewFiles($('photos'), $('publishPreviews')); });
$('publishForm').addEventListener('submit', async e => {
  e.preventDefault(); $('publishError').hidden = true; const form = e.currentTarget; const button = form.querySelector('button[type="submit"]');
  if (!currentUser) { $('publishDialog').close(); openAuth(); return; }
  let uploaded = []; button.disabled = true; button.textContent = 'Publicando...';
  try {
    const location = locationValues(form); const files = validateFiles($('photos')); const d = new FormData(form); uploaded = await uploadPhotos(files);
    const row = { ...location, owner_id: currentUser.id, title: String(d.get('title')).trim(), category: String(d.get('category')), description: String(d.get('description')).trim(), owned_time: String(d.get('ownedTime')).trim(), reason: String(d.get('reason')).trim(), wanted: String(d.get('wanted')).trim(), photo_path: uploaded[0], photo_paths: uploaded };
    const { error } = await db.from('publications').insert(row); if (error) throw error;
    form.reset(); fillLocalities(form.elements.namedItem('locality'), '', 'Seleccionar localidad'); clearPreview($('publishPreviews')); $('publishDialog').close(); $('search').value = ''; $('category').value = ''; $('provinceFilter').value = ''; fillLocalities($('localityFilter'), '', 'Todas las localidades'); await loadItems();
  } catch (error) { await removePhotos(uploaded); $('publishError').textContent = displayError(error); $('publishError').hidden = false; }
  finally { button.disabled = false; button.textContent = 'Publicar'; }
});
let chatOffer = null;
let chatTimer = null;
let chatGeneration = 0;
let chatLoading = false;
let chatLastSignature = '';
function stopChat() {
  if (chatTimer) clearInterval(chatTimer);
  chatTimer = null; chatOffer = null; chatGeneration++; chatLoading = false; chatLastSignature = '';
}
async function openOfferChat(entry) {
  if (!currentUser) return;
  stopChat(); chatOffer = entry.offer;
  $('chatTitle').textContent = 'Chat · ' + entry.publication_title;
  $('chatSubtitle').textContent = 'Propuesta: ' + (entry.offer.title || entry.offer.offered_item);
  $('chatMessages').replaceChildren(); $('chatError').hidden = true; $('chatForm').reset();
  const closed = !['pending', 'accepted'].includes(chatOffer.status);
  $('chatForm').hidden = closed;
  $('chatInfo').textContent = closed ? 'La propuesta está cerrada. Podés consultar el historial.' : 'Solo las dos personas de esta propuesta pueden ver los mensajes.';
  $('chatDialog').showModal();
  await loadChatMessages();
  if (chatOffer && $('chatDialog').open) chatTimer = setInterval(loadChatMessages, 5000);
}
async function loadChatMessages() {
  if (!chatOffer || !currentUser || chatLoading) return;
  chatLoading = true;
  const generation = chatGeneration; const userId = currentUser.id; const offerId = chatOffer.id;
  try {
    const { data, error } = await db.from('offer_messages').select('id,sender_id,body,created_at').eq('offer_id', offerId).order('created_at', { ascending: false }).order('id', { ascending: false }).limit(100);
    if (generation !== chatGeneration || currentUser?.id !== userId) return;
    if (error) throw error;
    $('chatError').hidden = true;
    const signature = JSON.stringify(data);
    if (signature === chatLastSignature) return;
    chatLastSignature = signature;
    const box = $('chatMessages'); const nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80; const initial = !box.childElementCount;
    box.replaceChildren();
    if (!data.length) { const p = document.createElement('p'); p.className = 'hint'; p.textContent = 'Todavía no hay mensajes. Iniciá la conversación.'; box.append(p); }
    for (const msg of [...data].reverse()) {
      const row = document.createElement('div'); row.className = 'chat-message' + (msg.sender_id === userId ? ' own' : '');
      const author = document.createElement('strong'); author.textContent = msg.sender_id === userId ? 'Vos' : (msg.sender_id === chatOffer.sender_id ? chatOffer.sender_name : 'Dueño de la publicación');
      const body = document.createElement('p'); body.textContent = msg.body;
      const time = document.createElement('time'); time.dateTime = msg.created_at; time.textContent = new Date(msg.created_at).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
      row.append(author, body, time); box.append(row);
    }
    if (nearBottom || initial) box.scrollTop = box.scrollHeight;
  } catch (error) {
    if (generation === chatGeneration) { $('chatError').textContent = displayError(error); $('chatError').hidden = false; }
  } finally { if (generation === chatGeneration) chatLoading = false; }
}
$('chatForm').addEventListener('submit', async e => {
  e.preventDefault();
  if (!currentUser || !chatOffer) return;
  const input = $('chatInput'); const body = input.value.trim(); if (!body) return;
  const offerId = chatOffer.id; const generation = chatGeneration; const button = $('chatSend');
  button.disabled = true; $('chatError').hidden = true;
  try {
    const { error } = await db.from('offer_messages').insert({ offer_id: offerId, sender_id: currentUser.id, body });
    if (error) throw error;
    if (generation !== chatGeneration) return;
    input.value = ''; await loadChatMessages(); $('chatMessages').scrollTop = $('chatMessages').scrollHeight;
  } catch (error) { if (generation === chatGeneration) { $('chatError').textContent = 'No se pudo enviar. La propuesta puede haberse cerrado: ' + displayError(error); $('chatError').hidden = false; } }
  finally { button.disabled = false; }
});
$('chatDialog').addEventListener('close', stopChat);

if (!db) { message('Configurá config.js con la URL y la clave publicable de Supabase para activar la aplicación.'); render(); }
else { db.auth.onAuthStateChange((_event, session) => { currentUser = session?.user || null; updateAccount(); }); db.auth.getUser().then(({ data }) => { currentUser = data.user; updateAccount(); }); loadItems(); }

async function openMyPublications() {
  if (!currentUser) return;
  const userId = currentUser.id;
  const box = $('myPublicationsList'); box.textContent = 'Cargando...';
  if (!$('myPublicationsDialog').open) $('myPublicationsDialog').showModal();
  const { data, error } = await db.from('publications').select('*').eq('owner_id', userId).order('created_at', { ascending: false });
  if (currentUser?.id !== userId) return;
  if (error) { box.textContent = displayError(error); return; }
  box.replaceChildren();
  if (!data.length) { box.textContent = 'Todavía no tenés publicaciones.'; return; }
  for (const item of data) {
    const row = document.createElement('article'); row.className = 'offer-row';
    const h = document.createElement('h3'); h.textContent = item.title;
    const expired = item.status === 'active' && new Date(item.expires_at) <= new Date();
    const status = document.createElement('p'); status.textContent = item.status === 'reserved' ? 'Permuta aceptada · Esperando la confirmación de las dos partes' : item.status === 'exchanged' ? 'Permutada' : expired ? 'Vencida · Los demás no la ven. Renovala para volver a ofrecerla.' : 'Activa · Vence el ' + shortDate(item.expires_at);
    const actions = document.createElement('div'); actions.className = 'manage-actions';
    const edit = document.createElement('button'); edit.textContent = 'Editar'; edit.addEventListener('click', () => openEditPublication(item));
    const renew = document.createElement('button'); renew.textContent = 'Renovar 2 semanas'; renew.hidden = item.status !== 'active';
    renew.addEventListener('click', async () => {
      if (!currentUser || currentUser.id !== item.owner_id) return;
      renew.disabled = true;
      try {
        const { error } = await db.rpc('renew_publication', { publication_id: item.id }); if (error) throw error;
        await loadItems(); await openMyPublications();
      } catch (error) { alert(displayError(error)); renew.disabled = false; }
    });
    const remove = document.createElement('button'); remove.textContent = 'Eliminar'; remove.className = 'danger';
    remove.addEventListener('click', async () => {
      if (!currentUser || currentUser.id !== item.owner_id) return;
      if (!confirm(`¿Eliminar “${item.title}”? También se eliminarán sus propuestas. Esta acción no se puede deshacer.`)) return;
      remove.disabled = true;
      try {
        const { data: deleted, error } = await db.from('publications').delete().eq('id', item.id).eq('owner_id', currentUser.id).select('id');
        if (error) throw error;
        if (!deleted.length) throw Error('La publicación ya no está disponible.');
        const { error: photoError } = await db.storage.from('publication-photos').remove(pathsFor(item));
        await loadItems(); await openMyPublications();
        if (photoError) alert('La publicación se eliminó, pero no pudimos borrar sus fotos de Storage: ' + displayError(photoError));
      } catch (error) { alert(displayError(error)); remove.disabled = false; }
    });
    actions.append(renew, edit, remove); row.append(h, status, detailLine('Ubicación: ', locationText(item)), gallery(pathsFor(item), item.title), actions); box.append(row);
  }
}
function openEditPublication(item) {
  if (currentUser?.id !== item.owner_id) return;
  const box = $('editPublicationContent'); box.replaceChildren();
  const heading = document.createElement('h2'); heading.textContent = 'Editar publicación';
  const form = document.createElement('form'); form.className = 'form';
  form.append(field('Título', 'title', 'text', 70), categorySelect('category'), field('Descripción y estado', 'description', 'textarea', 500), field('¿Hace cuánto lo tenés?', 'ownedTime', 'text', 80), field('¿Por qué lo publicás?', 'reason', 'textarea', 300), field('Busco a cambio', 'wanted', 'text', 100));
  form.append(...locationFields(item));
  const values = { title: item.title, category: item.category, description: item.description, ownedTime: item.owned_time, reason: item.reason, wanted: item.wanted };
  for (const [name, value] of Object.entries(values)) form.elements.namedItem(name).value = value;
  const current = document.createElement('p'); current.textContent = 'Fotos actuales';
  const [photoLabel, previews] = photoField('editPhotos', 'editPreviews');
  const input = photoLabel.querySelector('input'); input.required = false;
  photoLabel.firstChild.textContent = 'Reemplazar fotos (opcional, 1 a 5)';
  const hint = document.createElement('p'); hint.className = 'hint'; hint.textContent = 'Si no elegís fotos nuevas, conservamos las actuales. Si elegís nuevas, reemplazan todas las anteriores.';
  const errorBox = document.createElement('p'); errorBox.className = 'error'; errorBox.hidden = true; errorBox.setAttribute('role', 'alert');
  const submit = document.createElement('button'); submit.type = 'submit'; submit.className = 'primary'; submit.textContent = 'Guardar cambios';
  form.append(current, gallery(pathsFor(item), item.title), photoLabel, previews, hint, errorBox, submit);
  form.addEventListener('submit', async e => {
    e.preventDefault(); errorBox.hidden = true;
    if (currentUser?.id !== item.owner_id) return;
    const d = new FormData(form); let uploaded = []; let committed = false;
    submit.disabled = true; submit.textContent = 'Guardando...';
    try {
      const changes = { ...locationValues(form), title: String(d.get('title')).trim(), category: String(d.get('category')), description: String(d.get('description')).trim(), owned_time: String(d.get('ownedTime')).trim(), reason: String(d.get('reason')).trim(), wanted: String(d.get('wanted')).trim() };
      if (Object.values(changes).some(value => !value)) throw Error('Completá todos los campos.');
      if (input.files.length) { uploaded = await uploadPhotos(validateFiles(input)); changes.photo_path = uploaded[0]; changes.photo_paths = uploaded; }
      const { data, error } = await db.from('publications').update(changes).eq('id', item.id).eq('owner_id', currentUser.id).select('id');
      if (error) throw error;
      if (!data.length) throw Error('La publicación ya no está disponible.');
      committed = true;
      let photoError;
      if (uploaded.length) ({ error: photoError } = await db.storage.from('publication-photos').remove(pathsFor(item)));
      clearPreview(previews); $('editPublicationDialog').close(); await loadItems(); await openMyPublications();
      if (photoError) alert('Los cambios se guardaron, pero no pudimos borrar las fotos anteriores: ' + displayError(photoError));
    } catch (error) { if (!committed) await removePhotos(uploaded); errorBox.textContent = displayError(error); errorBox.hidden = false; }
    finally { submit.disabled = false; submit.textContent = 'Guardar cambios'; }
  });
  box.append(heading, form); $('editPublicationDialog').showModal();
}
$('myPublicationsBtn').addEventListener('click', openMyPublications);
$('editPublicationDialog').addEventListener('close', () => { const previews = $('editPreviews'); if (previews) clearPreview(previews); });

function memberSince(date) { return 'Miembro desde ' + new Date(date).toLocaleDateString('es-AR', { month: 'long', year: 'numeric' }); }
function avatarImage(profile) {
  const img = document.createElement('img'); img.className = 'avatar'; img.alt = profile?.avatar_path ? 'Foto de ' + profile.display_name : '';
  img.src = profile?.avatar_path ? photoUrl(profile.avatar_path) : 'data:image/svg+xml,' + encodeURIComponent("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'><rect width='64' height='64' fill='#dce9df'/><circle cx='32' cy='25' r='11' fill='#8fb3a6'/><path d='M12 56c3-12 11-18 20-18s17 6 20 18' fill='#8fb3a6'/></svg>");
  return img;
}
async function openMyProfile() {
  if (!currentUser) return;
  const userId = currentUser.id;
  const box = $('profileContent'); box.textContent = 'Cargando...';
  if (!$('profileDialog').open) $('profileDialog').showModal();
  const profile = await loadMyProfile();
  if (currentUser?.id !== userId) return;
  box.replaceChildren();
  const heading = document.createElement('h2'); heading.textContent = 'Mi perfil';
  const intro = document.createElement('p'); intro.textContent = 'Así te ven las demás personas en permutON. Tu email y tus datos de contacto no se muestran en el perfil. ';
  const viewPublic = document.createElement('button'); viewPublic.type = 'button'; viewPublic.className = 'link-btn'; viewPublic.textContent = 'Ver mi perfil público'; viewPublic.addEventListener('click', () => openPublicProfile(userId)); intro.append(viewPublic);
  const head = document.createElement('div'); head.className = 'profile-head';
  const avatar = avatarImage(profile); const since = document.createElement('p'); since.className = 'hint'; since.textContent = profile ? memberSince(profile.created_at) : '';
  head.append(avatar, since);
  const form = document.createElement('form'); form.className = 'form';
  const name = field('Nombre visible', 'displayName', 'text', 40); name.querySelector('input').minLength = 2;
  const bio = field('Sobre vos (opcional)', 'bio', 'textarea', 300, 'Ej. Me gusta el deporte y cambio ropa que ya no uso.'); bio.querySelector('textarea').required = false;
  const location = locationFields(profile || {}); location.forEach(label => { label.querySelector('select').required = false; label.firstChild.textContent += ' (opcional)'; });
  const photoLabel = document.createElement('label'); photoLabel.textContent = 'Foto de perfil (opcional)';
  const photoInput = document.createElement('input'); photoInput.type = 'file'; photoInput.accept = 'image/jpeg,image/png,image/webp'; photoLabel.append(photoInput);
  const removeLabel = document.createElement('label'); removeLabel.className = 'checkbox'; const removeInput = document.createElement('input'); removeInput.type = 'checkbox';
  removeLabel.append(removeInput, document.createTextNode('Quitar mi foto actual')); removeLabel.hidden = !profile?.avatar_path;
  let previewUrl = null;
  photoInput.addEventListener('change', () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl); previewUrl = null;
    const file = photoInput.files[0]; if (!file) { avatar.src = avatarImage(profile).src; return; }
    previewUrl = URL.createObjectURL(file); avatar.src = previewUrl; removeInput.checked = false;
  });
  const errorBox = document.createElement('p'); errorBox.className = 'error'; errorBox.hidden = true; errorBox.setAttribute('role', 'alert');
  const submit = document.createElement('button'); submit.type = 'submit'; submit.className = 'primary'; submit.textContent = 'Guardar perfil';
  form.append(name, bio, ...location, photoLabel, removeLabel, errorBox, submit);
  form.elements.namedItem('displayName').value = profile?.display_name || '';
  form.elements.namedItem('bio').value = profile?.bio || '';
  form.addEventListener('submit', async e => {
    e.preventDefault(); errorBox.hidden = true;
    if (currentUser?.id !== userId) return;
    let uploaded = null; let committed = false;
    submit.disabled = true; submit.textContent = 'Guardando...';
    try {
      const displayName = form.elements.namedItem('displayName').value.trim();
      if (displayName.length < 2) throw Error('El nombre debe tener al menos 2 letras.');
      const province = form.elements.namedItem('province').value; const locality = form.elements.namedItem('locality').value;
      const place = !province && !locality ? { province_id: null, locality_id: null } : locationValues(form);
      const changes = { display_name: displayName, bio: form.elements.namedItem('bio').value.trim() || null, ...place };
      const file = photoInput.files[0];
      if (file) {
        if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 8 * 1024 * 1024) throw Error('La foto debe ser JPG, PNG o WebP y pesar hasta 8 MB.');
        const blob = await compressPhoto(file, 400); uploaded = `${userId}/avatar-${crypto.randomUUID()}.jpg`;
        const { error } = await db.storage.from('publication-photos').upload(uploaded, blob, { contentType: 'image/jpeg', upsert: false });
        if (error) { uploaded = null; throw error; }
        changes.avatar_path = uploaded;
      } else if (removeInput.checked) changes.avatar_path = null;
      const query = profile ? db.from('profiles').update(changes).eq('id', userId) : db.from('profiles').insert({ id: userId, ...changes });
      const { error } = await query; if (error) throw error;
      committed = true;
      if (profile?.avatar_path && 'avatar_path' in changes) await removePhotos([profile.avatar_path]);
      await loadMyProfile();
      if (currentUser?.id === userId) { $('profileDialog').close(); loadItems(); }
    } catch (error) { if (!committed && uploaded) await removePhotos([uploaded]); errorBox.textContent = displayError(error); errorBox.hidden = false; }
    finally { submit.disabled = false; submit.textContent = 'Guardar perfil'; }
  });
  $('profileDialog').addEventListener('close', () => { if (previewUrl) URL.revokeObjectURL(previewUrl); previewUrl = null; }, { once: true });
  box.append(heading, intro, head, form);
}
$('profileBtn').addEventListener('click', openMyProfile);

function lastActivityText(day) {
  if (!day) return '';
  const [y, m, d] = day.split('-').map(Number); const today = new Date(); today.setHours(0, 0, 0, 0);
  const days = Math.round((today - new Date(y, m - 1, d)) / 86400000);
  return 'Última actividad: ' + (days <= 0 ? 'hoy' : days === 1 ? 'ayer' : days < 7 ? 'esta semana' : days < 31 ? 'este mes' : 'hace más de un mes');
}
function responseTimeText(hours) {
  if (hours === null || hours === undefined) return '—';
  if (hours < 1) return 'menos de 1 h';
  if (hours < 24) return hours + ' h';
  const days = Math.round(hours / 24); return days + (days === 1 ? ' día' : ' días');
}
function statTile(value, label) {
  const tile = document.createElement('div'); tile.className = 'stat';
  const strong = document.createElement('strong'); strong.textContent = value; const span = document.createElement('span'); span.textContent = label;
  tile.append(strong, span); return tile;
}
let publicProfileGeneration = 0;
async function openPublicProfile(userId) {
  if (!db || !userId) return;
  const generation = ++publicProfileGeneration;
  const box = $('publicProfileContent'); box.textContent = 'Cargando perfil...';
  if (!$('publicProfileDialog').open) $('publicProfileDialog').showModal();
  const [profileRes, statsRes, pubsRes] = await Promise.all([
    db.from('profiles').select('id,display_name,bio,province_id,locality_id,avatar_path,created_at').eq('id', userId).maybeSingle(),
    db.rpc('get_profile_stats', { target_user: userId }),
    db.from('publications').select('*').eq('owner_id', userId).in('status', ['active', 'reserved', 'exchanged']).order('created_at', { ascending: false }).limit(60)
  ]);
  if (generation !== publicProfileGeneration) return;
  const error = profileRes.error || statsRes.error || pubsRes.error;
  if (error) { box.textContent = 'No pudimos cargar el perfil: ' + displayError(error); return; }
  const profile = profileRes.data;
  if (!profile) { box.textContent = 'Este perfil ya no existe.'; return; }
  const stats = statsRes.data || {}; const pubs = pubsRes.data || [];
  box.replaceChildren();

  const head = document.createElement('div'); head.className = 'profile-head';
  const info = document.createElement('div');
  const name = document.createElement('h2'); name.textContent = profile.display_name; info.append(name);
  if (profile.locality_id) { const place = document.createElement('p'); place.className = 'hint'; place.textContent = locationText(profile); info.append(place); }
  const since = document.createElement('p'); since.className = 'hint'; since.textContent = memberSince(profile.created_at); info.append(since);
  const activity = lastActivityText(stats.last_activity);
  if (activity) { const p = document.createElement('p'); p.className = 'hint'; p.textContent = activity; info.append(p); }
  head.append(avatarImage(profile), info); box.append(head);
  if (profile.bio) { const bio = document.createElement('p'); bio.textContent = profile.bio; box.append(bio); }
  if (currentUser?.id === profile.id) { const own = document.createElement('p'); own.className = 'success'; own.textContent = 'Así ven tu perfil las demás personas.'; box.append(own); }

  const received = stats.offers_received || 0;
  const grid = document.createElement('div'); grid.className = 'stats';
  grid.append(
    statTile(String(stats.completed_trades || 0), 'Permutas concretadas'),
    statTile(String(stats.active_publications || 0), 'Publicaciones disponibles'),
    statTile(received ? Math.round((stats.offers_answered || 0) / received * 100) + '%' : '—', received ? 'Responde las propuestas que recibe' : 'Todavía no recibió propuestas'),
    statTile(responseTimeText(stats.avg_response_hours), 'Tiempo de respuesta promedio'),
    statTile(String(stats.unanswered_trades || 0), 'Permutas que dejó sin confirmar')
  );
  box.append(grid);

  const available = pubs.filter(p => p.status === 'active' && new Date(p.expires_at) > new Date()); const history = pubs.filter(p => p.status !== 'active');
  const tabs = document.createElement('div'); tabs.className = 'manage-actions';
  const list = document.createElement('div'); list.className = 'mini-grid';
  const tabButtons = [['Disponibles', available], ['Historial', history]].map(([label, records], index) => {
    const button = document.createElement('button'); button.type = 'button'; button.textContent = `${label} (${records.length})`;
    button.addEventListener('click', () => showTab(index)); tabs.append(button); return [button, records, label];
  });
  function showTab(index) {
    tabButtons.forEach(([button], i) => button.setAttribute('aria-pressed', String(i === index)));
    const records = tabButtons[index][1]; list.replaceChildren();
    if (!records.length) { const p = document.createElement('p'); p.className = 'hint'; p.textContent = index === 0 ? 'No tiene publicaciones disponibles en este momento.' : 'Todavía no tiene permutas en su historial.'; list.append(p); return; }
    for (const item of records) {
      const card = document.createElement('article'); card.className = 'card'; const body = document.createElement('div'); body.className = 'card-body';
      const status = document.createElement('div'); status.className = 'meta'; status.textContent = publicationStatusLabels[item.status] + ' · ' + item.category;
      const title = document.createElement('h3'); title.textContent = item.title;
      const view = document.createElement('button'); view.type = 'button'; view.textContent = 'Ver'; view.addEventListener('click', () => openDetail(item));
      body.append(status, title, view); card.append(imageFor(item), body); list.append(card);
    }
  }
  showTab(0);
  box.append(tabs, list);
}

async function loadNotificationCount() {
  if (!db || !currentUser) return;
  const userId = currentUser.id;
  const { count, error } = await db.from('notifications').select('id', { count: 'exact', head: true }).is('read_at', null);
  if (error || currentUser?.id !== userId) return;
  $('notificationsBtn').textContent = count ? `Avisos (${count})` : 'Avisos';
}
async function openOffersFor(offerId) {
  await loadMyOffers();
  const entry = offerEntries.find(e => e.offer.id === offerId);
  if (entry && entry.direction !== offerDirection) { offerDirection = entry.direction; renderMyOffers(); }
}
async function openNotifications() {
  if (!currentUser) return;
  const userId = currentUser.id; const box = $('notificationsList'); box.textContent = 'Cargando...';
  if (!$('notificationsDialog').open) $('notificationsDialog').showModal();
  const { data, error } = await db.from('notifications').select('*').order('created_at', { ascending: false }).limit(50);
  if (currentUser?.id !== userId) return;
  if (error) { box.textContent = displayError(error); return; }
  box.replaceChildren();
  if (!data.length) { box.textContent = 'No tenés avisos todavía.'; return; }
  for (const n of data) {
    const row = document.createElement('article'); row.className = 'notification' + (n.read_at ? '' : ' unread');
    const title = document.createElement('strong'); title.textContent = n.title;
    const body = document.createElement('p'); body.textContent = n.body;
    const time = document.createElement('time'); time.dateTime = n.created_at; time.className = 'hint'; time.textContent = shortDate(n.created_at);
    row.append(title, body, time);
    const go = document.createElement('button'); go.type = 'button'; go.className = 'link-btn';
    if (n.kind.startsWith('publication_')) { go.textContent = 'Ir a Mis publicaciones'; go.addEventListener('click', () => { $('notificationsDialog').close(); openMyPublications(); }); row.append(go); }
    else if (n.offer_id) { go.textContent = 'Ir a Mis propuestas'; go.addEventListener('click', () => { $('notificationsDialog').close(); openOffersFor(n.offer_id); }); row.append(go); }
    box.append(row);
  }
  const unread = data.filter(n => !n.read_at).map(n => n.id);
  if (unread.length) { await db.from('notifications').update({ read_at: new Date().toISOString() }).in('id', unread); loadNotificationCount(); }
}
$('notificationsBtn').addEventListener('click', openNotifications);
setInterval(() => { if (currentUser && !document.hidden) loadNotificationCount(); }, 30000);

// Mantener el catálogo al día cuando otros usuarios aceptan permutas.
setInterval(() => { if (db && !document.hidden) loadItems(); }, 15000);
