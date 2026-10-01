import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const SUPABASE_URL = 'https://encicvbzmsvmxgjmytmx.supabase.co';
const SUPABASE_KEY = 'sb_publishable_0q9P3ZygS4KdRVKkvNZ7oA_N_r7Mg1J';
const db = createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { persistSession: false } });

const STATUS = {
  kupuji: 'Kupuji',
  objednano: 'Objednáno',
  koupeno: 'Koupeno',
};
const PRIORITY = { 1: 'Přál(a) bych si', 2: 'Moc bych si přál(a)', 3: 'Nejvíc ze všeho' };

const app = document.getElementById('app');
const top = document.getElementById('top');
const side = document.getElementById('side');
const toastEl = document.getElementById('toast');

let email = load('email');
let state = null;             // výsledek get_state
let view = load('view') || 'mine';
let person = load('person');  // vybraná osoba v „Přání ostatních“

// ---------------------------------------------------------------- pomocné

function load(key) { try { return localStorage.getItem('jezisek.' + key); } catch { return null; } }
function save(key, value) {
  try { value == null ? localStorage.removeItem('jezisek.' + key) : localStorage.setItem('jezisek.' + key, value); } catch { }
}

/** Vytvoří element. Text se vkládá vždy jako text (nikdy jako HTML). */
function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = v;
    else if (k in el && typeof v !== 'string') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  return fill(el, ...children);
}

/** Nahradí obsah elementu. Pole rozbalí, prázdné hodnoty (null, false) vynechá. */
function fill(el, ...children) {
  el.replaceChildren(...children.flat(Infinity)
    .filter(c => c != null && c !== false)
    .map(c => c instanceof Node ? c : document.createTextNode(String(c))));
  return el;
}

let toastTimer;
function toast(msg, error = false) {
  toastEl.textContent = msg;
  toastEl.className = 'toast' + (error ? ' error' : '');
  toastEl.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toastEl.hidden = true; }, error ? 5000 : 2500);
}

async function rpc(fn, args = {}) {
  const { data, error } = await db.rpc(fn, { p_email: email, ...args });
  if (error) {
    const msg = error.code === 'P0001' ? error.message : 'Něco se nepovedlo. Zkus to prosím znovu.';
    toast(msg, true);
    console.error(fn, error);
    throw error;
  }
  return data;
}

/** Provede akci, znovu načte data a překreslí stránku. Tlačítko mezitím zablokuje. */
async function act(button, fn, okMsg) {
  if (button) button.disabled = true;
  try {
    await fn();
    await refresh();
    if (okMsg) toast(okMsg);
  } catch {
    if (button) button.disabled = false;
  }
}

const name = id => state.members.find(m => m.id === id)?.name ?? '?';
const photoUrl = path => `${SUPABASE_URL}/storage/v1/object/public/photos/${path}`;
const stars = n => '★'.repeat(n) + '☆'.repeat(3 - n);

// ---------------------------------------------------------------- start

async function start() {
  if (!email) return renderLogin();
  try {
    await refresh();
  } catch {
    renderLogin();
  }
}

async function refresh() {
  state = await rpc('get_state');
  render();
}

function setView(v) {
  view = v;
  save('view', v);
  render();
  window.scrollTo(0, 0);
}

document.getElementById('tabs').addEventListener('click', e => {
  const v = e.target.closest('button')?.dataset.view;
  if (v) setView(v);
});

function render() {
  top.hidden = false;
  for (const b of document.querySelectorAll('#tabs button')) b.classList.toggle('active', b.dataset.view === view);
  fill(app,
    view === 'others' ? renderOthers() :
    view === 'settings' ? renderSettings() :
    renderMine());
  renderSide();
}

// ---------------------------------------------------------------- přehled vlevo

/** Kompaktní seznam všech přání (moje + ostatních), seskupený podle lidí. */
function renderSide() {
  side.hidden = false;
  const me = state.me.id;
  const groups = [
    { id: me, name: 'Já', wishes: state.my_wishes, mine: true },
    ...state.members.filter(m => m.id !== me).map(m => ({
      id: m.id, name: m.name,
      wishes: state.others_wishes.filter(w => w.owner_id === m.id && !w.cancelled),
    })),
  ];

  const mark = w => {
    const p = w.purchase;
    if (!p) return w.contributors?.length ? h('span', { class: 'mark', title: 'Někdo se chce složit' }, '◦') : null;
    return p.status === 'koupeno'
      ? h('span', { class: 'mark done', title: 'Koupeno' }, '✓')
      : h('span', { class: 'mark busy', title: STATUS[p.status] }, '●');
  };

  const list = groups.map(g => h('div', { class: 'side-group' },
    h('div', { class: 'side-name' }, g.name, h('span', { class: 'side-count' }, g.wishes.length)),
    g.wishes.length
      ? h('ul', {}, g.wishes.map(w => h('li', {},
          h('button', {
            class: 'side-item',
            onclick: () => jumpTo(w, g),
          }, h('span', { class: 'side-stars' }, '★'.repeat(w.priority)), h('span', { class: 'side-title' }, w.title), !g.mine && mark(w)))))
      : h('p', { class: 'side-empty' }, 'zatím nic')));

  // na úzké obrazovce je přehled sbalený nahoře, na široké je trvale vlevo
  const wasOpen = side.querySelector('details')?.open;
  fill(side, h('details', { open: wasOpen || matchMedia('(min-width: 1000px)').matches },
    h('summary', {}, 'Přehled všech přání'),
    list,
    h('p', { class: 'side-legend' }, '● někdo kupuje · ✓ koupeno · ◦ chtějí se složit')));
}

function jumpTo(w, g) {
  if (g.mine) view = 'mine';
  else { view = 'others'; person = g.id; save('person', person); }
  save('view', view);
  render();
  const card = document.getElementById('w-' + w.id);
  if (!card) return;
  card.scrollIntoView({ behavior: 'smooth', block: 'center' });
  card.classList.add('flash');
  setTimeout(() => card.classList.remove('flash'), 1600);
  if (!matchMedia('(min-width: 1000px)').matches) side.querySelector('details').open = false;
}

// ---------------------------------------------------------------- přihlášení

function renderLogin(message) {
  top.hidden = true;
  side.hidden = true;
  const input = h('input', { type: 'email', id: 'email', autocomplete: 'email', required: true, placeholder: 'např. jana@seznam.cz' });
  const button = h('button', { class: 'primary big', type: 'submit' }, 'Vstoupit');
  fill(app, h('div', { class: 'login' },
    h('img', { src: 'img/logo-512.png', alt: '' }),
    h('h1', {}, 'Ježíšek'),
    h('p', { class: 'muted' }, 'Rodinný seznam vánočních přání'),
    message && h('div', { class: 'alert red' }, message),
    h('form', {
      onsubmit: async e => {
        e.preventDefault();
        button.disabled = true;
        const { data, error } = await db.rpc('login', { p_email: input.value });
        button.disabled = false;
        if (error) return toast('Nepodařilo se spojit se serverem.', true);
        if (!data) return renderLogin('Tento e-mail neznám. Požádej správce, ať tě přidá.');
        email = data.email;
        save('email', email);
        view = 'mine';
        save('view', view);
        start();
      },
    },
      h('label', { for: 'email' }, 'Tvůj e-mail'),
      input,
      button)));
  input.focus();
}

function logout() {
  email = null;
  state = null;
  save('email', null);
  save('person', null);
  renderLogin();
}

// ---------------------------------------------------------------- moje přání

function renderMine() {
  const wishes = state.my_wishes;
  return h('div', {},
    h('h1', {}, `Ahoj, ${state.me.name}!`),
    h('p', { class: 'muted' }, 'Tady si zapiš, co by sis přál(a) k Vánocům. Tvoje přání uvidí všichni ostatní. Co z toho kupují, neuvidíš – ať je to překvapení.'),
    h('button', { class: 'gold big', onclick: () => renderForm(null, state.me.id) }, '+ Přidat přání'),
    h('div', { style: 'height:20px' }),
    wishes.length
      ? wishes.map(w => wishCard(w, [
          h('button', { onclick: () => renderForm(w, state.me.id) }, 'Upravit'),
          h('button', { class: 'danger', onclick: e => removeWish(e.target, w) }, 'Smazat'),
        ]))
      : h('p', { class: 'empty' }, 'Zatím tu nemáš žádné přání.'));
}

function wishCard(w, actions, extra) {
  return h('div', { class: 'card wish' + (w.cancelled ? ' cancelled' : ''), id: 'w-' + w.id },
    h('div', { class: 'wish-head' },
      h('h3', {}, w.title),
      h('span', { class: 'stars', title: PRIORITY[w.priority] }, stars(w.priority))),
    h('p', { class: 'muted', style: 'font-size:.85rem' }, PRIORITY[w.priority]),
    w.photo_path && h('a', { class: 'photo', href: photoUrl(w.photo_path), target: '_blank' },
      h('img', { src: photoUrl(w.photo_path), alt: w.title, loading: 'lazy' })),
    w.description && h('p', {}, w.description),
    w.note && h('p', { class: 'note' }, 'Poznámka: ', w.note),
    extra,
    actions?.length && h('div', { class: 'row actions' }, actions));
}

function removeWish(button, w) {
  if (!confirm(`Opravdu smazat přání „${w.title}“?`)) return;
  act(button, () => rpc('delete_wish', { p_id: w.id }), 'Přání smazáno');
}

// ---------------------------------------------------------------- formulář přání

function renderForm(w, ownerId) {
  const isTip = ownerId !== state.me.id;
  let priority = w?.priority ?? 1;
  let photoPath = w?.photo_path ?? null;
  let photoFile = null;

  const title = h('input', { type: 'text', id: 'f-title', value: w?.title ?? '', maxlength: 200 });
  const desc = h('textarea', { id: 'f-desc' }, w?.description ?? '');
  const note = h('textarea', { id: 'f-note', style: 'min-height:70px' }, w?.note ?? '');
  const prio = h('div', { class: 'choice' });
  const photoBox = h('div', { class: 'photo-edit' });
  const fileInput = h('input', {
    type: 'file', accept: 'image/*', hidden: true,
    onchange: () => { photoFile = fileInput.files[0] || null; drawPhoto(); },
  });
  const saveBtn = h('button', { class: 'primary big', type: 'submit' }, 'Uložit');

  function drawPrio() {
    fill(prio, ...[1, 2, 3].map(n => h('button', {
      type: 'button', class: n === priority ? 'on' : '',
      onclick: () => { priority = n; drawPrio(); },
    }, stars(n), h('br'), PRIORITY[n])));
  }

  function drawPhoto() {
    const src = photoFile ? URL.createObjectURL(photoFile) : photoPath && photoUrl(photoPath);
    fill(photoBox, 
      src && h('img', { src, alt: '' }),
      h('div', { class: 'row' },
        h('button', { type: 'button', onclick: () => fileInput.click() }, src ? 'Vyměnit fotku' : 'Přidat fotku'),
        src && h('button', { type: 'button', class: 'danger', onclick: () => { photoFile = null; photoPath = null; fileInput.value = ''; drawPhoto(); } }, 'Odebrat fotku')),
      fileInput);
  }

  drawPrio();
  drawPhoto();

  top.hidden = false;
  fill(app, h('form', {
    class: 'card',
    onsubmit: async e => {
      e.preventDefault();
      if (!title.value.trim()) { toast('Vyplň prosím název.', true); title.focus(); return; }
      saveBtn.disabled = true;
      saveBtn.textContent = 'Ukládám…';
      try {
        if (photoFile) photoPath = await uploadPhoto(photoFile);
        await rpc('save_wish', {
          p_id: w?.id ?? null, p_owner_id: ownerId, p_title: title.value,
          p_description: desc.value, p_priority: priority, p_note: note.value, p_photo_path: photoPath,
        });
        await refresh();
        toast('Uloženo');
        window.scrollTo(0, 0);
      } catch {
        saveBtn.disabled = false;
        saveBtn.textContent = 'Uložit';
      }
    },
  },
    h('h2', {}, w ? 'Upravit přání' : isTip ? `Tip na dárek pro: ${name(ownerId)}` : 'Nové přání'),
    isTip && h('p', { class: 'muted' }, `${name(ownerId)} tento tip neuvidí. Uvidí ho jen ostatní.`),
    h('label', { for: 'f-title' }, 'Název ', h('span', { class: 'hint' }, '(povinné)')),
    title,
    h('label', { for: 'f-desc' }, 'Popis ', h('span', { class: 'hint' }, '(velikost, barva, kde se dá koupit…)')),
    desc,
    h('label', {}, 'Jak moc si to přeješ?'),
    prio,
    h('label', { for: 'f-note' }, 'Poznámka'),
    note,
    h('label', {}, 'Fotka'),
    photoBox,
    h('div', { style: 'height:24px' }),
    saveBtn,
    h('button', { type: 'button', class: 'big', style: 'margin-top:10px', onclick: () => render() }, 'Zpět bez uložení')));
  window.scrollTo(0, 0);
  if (!w) title.focus();
}

/** Zmenší fotku (telefony fotí zbytečně velké) a nahraje ji. Vrací cestu v úložišti. */
async function uploadPhoto(file) {
  let blob = file;
  try {
    const bmp = await createImageBitmap(file);
    const scale = Math.min(1, 1280 / Math.max(bmp.width, bmp.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bmp.width * scale);
    canvas.height = Math.round(bmp.height * scale);
    canvas.getContext('2d').drawImage(bmp, 0, 0, canvas.width, canvas.height);
    blob = await new Promise(r => canvas.toBlob(r, 'image/jpeg', 0.85));
  } catch (e) {
    console.warn('Fotku se nepodařilo zmenšit, nahrávám originál', e);
  }
  const path = `${state.year}/${crypto.randomUUID()}.jpg`;
  const { error } = await db.storage.from('photos').upload(path, blob, { contentType: blob.type || 'image/jpeg' });
  if (error) {
    toast('Fotku se nepodařilo nahrát.', true);
    throw error;
  }
  return path;
}

// ---------------------------------------------------------------- přání ostatních

function renderOthers() {
  const others = state.members.filter(m => m.id !== state.me.id);
  if (!others.length) return h('p', { class: 'empty' }, 'Zatím tu nikdo další není.');
  if (!others.some(m => m.id === person)) person = others[0].id;

  const count = id => state.others_wishes.filter(w => w.owner_id === id && !w.cancelled).length;
  const wishes = state.others_wishes.filter(w => w.owner_id === person);
  const who = name(person);

  return h('div', {},
    h('h1', {}, 'Přání ostatních'),
    h('p', { class: 'muted' }, 'Vyber, pro koho hledáš dárek. Co kdo kupuje, vidíte jen vy ostatní – obdarovaný ne.'),
    h('div', { class: 'people' }, others.map(m => h('button', {
      class: m.id === person ? 'on' : '',
      onclick: () => { person = m.id; save('person', person); render(); },
    }, m.name, h('span', { class: 'count' }, `${count(m.id)} přání`)))),
    h('h2', {}, `${who} si přeje:`),
    wishes.length ? wishes.map(othersCard) : h('p', { class: 'empty' }, `${who} si zatím nic nezapsal(a).`),
    h('button', { class: 'big', onclick: () => renderForm(null, person) }, `+ Přidat tip na dárek pro: ${who}`));
}

function othersCard(w) {
  const me = state.me.id;
  const p = w.purchase;
  const iBuy = p?.buyer_id === me;
  const iChip = w.contributors.includes(me);
  const mineTip = w.author_id === me && w.author_id !== w.owner_id;

  const alerts = [
    w.cancelled && h('div', { class: 'alert red' }, `${name(w.owner_id)} toto přání zrušil(a). Pokud už jsi dárek koupil(a), domluvte se.`),
    iBuy && p.changed && !w.cancelled && h('div', { class: 'alert gold' },
      'Přání bylo mezitím upraveno – zkontroluj, co se změnilo. ',
      h('button', { class: 'link', onclick: e => act(e.target, () => rpc('mark_seen', { p_wish: w.id })) }, 'Beru na vědomí')),
  ];

  // stav nákupu
  let buy;
  const chippers = w.contributors.map(name).join(', ');
  if (!p) {
    buy = h('div', { class: 'buy free' },
      h('div', { class: 'state' }, 'Volné – zatím to nikdo nekupuje'),
      chippers && h('p', {}, `Chtějí se složit: ${chippers}`),
      !w.cancelled && h('div', { class: 'row' },
        h('button', { class: 'primary', onclick: e => act(e.target, () => rpc('set_purchase', { p_wish: w.id, p_status: 'kupuji', p_note: '' }), 'Zapsáno – kupuješ to ty') }, 'Koupím to'),
        chipButton(w, iChip)));
  } else {
    buy = h('div', { class: 'buy' + (p.status === 'koupeno' ? ' done' : '') },
      h('div', { class: 'state' }, `${STATUS[p.status]} `, h('small', {}, `– kupuje ${iBuy ? 'ty' : name(p.buyer_id)}`)),
      chippers && h('p', {}, `Skládají se: ${chippers}`),
      p.note && h('p', {}, 'Poznámka k nákupu: ', p.note),
      iBuy ? buyerControls(w, p) : !w.cancelled && chipButton(w, iChip));
  }

  return wishCard(w,
    mineTip && [
      h('button', { onclick: () => renderForm(w, w.owner_id) }, 'Upravit tip'),
      h('button', { class: 'danger', onclick: e => removeWish(e.target, w) }, 'Smazat tip'),
    ],
    [
      w.author_id !== w.owner_id && h('span', { class: 'tag tip' }, `Tip od: ${w.author_id === me ? 'tebe' : name(w.author_id)}`),
      ...alerts,
      buy,
    ]);
}

function chipButton(w, on) {
  return on
    ? h('button', { onclick: e => act(e.target, () => rpc('set_contribution', { p_wish: w.id, p_on: false }), 'Už se neskládáš') }, 'Už se neskládám')
    : h('button', { onclick: e => act(e.target, () => rpc('set_contribution', { p_wish: w.id, p_on: true }), 'Zapsáno – skládáš se') }, 'Složím se');
}

function buyerControls(w, p) {
  const note = h('input', { type: 'text', value: p.note, placeholder: 'např. objednáno na Alze, přijde 10. 12.' });
  // ovládání je sbalené, aby karta nezabírala půl obrazovky
  return h(w.cancelled ? 'div' : 'details', { class: 'buy-edit' },
    !w.cancelled && [
      h('summary', {}, 'Změnit stav nebo poznámku'),
      h('label', {}, 'Jak to vypadá s nákupem?'),
      h('div', { class: 'choice' }, Object.entries(STATUS).map(([key, label]) => h('button', {
        class: p.status === key ? 'on' : '',
        onclick: e => act(e.target, () => rpc('set_purchase', { p_wish: w.id, p_status: key, p_note: note.value }), 'Uloženo'),
      }, label))),
      h('label', {}, 'Poznámka k nákupu ', h('span', { class: 'hint' }, '(uvidí ji jen ostatní kupující)')),
      note,
      h('button', { onclick: e => act(e.target, () => rpc('set_purchase', { p_wish: w.id, p_status: p.status, p_note: note.value }), 'Poznámka uložena') }, 'Uložit poznámku'),
    ],
    h('div', {},
      h('button', {
        class: 'danger',
        onclick: e => {
          if (confirm('Opravdu už to nekupuješ? Dárek bude znovu volný.'))
            act(e.target, () => rpc('set_purchase', { p_wish: w.id, p_status: null, p_note: null }), 'Dárek je znovu volný');
        },
      }, w.cancelled ? 'Odebrat ze seznamu' : 'Už to nekupuji')));
}

// ---------------------------------------------------------------- nastavení

function renderSettings() {
  const me = state.me;
  const opts = [
    ['p_new_wish', 'notify_new_wish', 'Někdo si přidal nové přání (nebo tip)'],
    ['p_wish_changed', 'notify_wish_changed', 'Přání, které kupuji nebo na které se skládám, se změnilo nebo bylo zrušeno'],
    ['p_contributor', 'notify_contributor', 'Někdo se chce složit na dárek, který kupuji'],
    ['p_status', 'notify_status', 'Změnil se stav dárku, na který se skládám'],
  ];
  const boxes = opts.map(([arg, key, text]) => {
    const input = h('input', { type: 'checkbox', checked: me[key] });
    input.dataset.arg = arg;
    return h('label', { class: 'check' }, input, h('span', {}, text));
  });

  return h('div', {},
    h('h1', {}, 'Nastavení'),
    h('div', { class: 'card' },
      h('h2', {}, 'Upozornění e-mailem'),
      h('p', { class: 'muted' }, `Zaškrtni, o čem ti má přijít e-mail na ${me.email}. Upozornění chodí nejvýš jednou za hodinu, shrnutá do jednoho e-mailu.`),
      boxes,
      h('button', {
        class: 'primary big', style: 'margin-top:12px',
        onclick: e => {
          const args = Object.fromEntries(boxes.map(b => { const i = b.querySelector('input'); return [i.dataset.arg, i.checked]; }));
          act(e.target, () => rpc('set_notifications', args), 'Upozornění uložena');
        },
      }, 'Uložit upozornění')),
    me.is_admin && adminPanel(),
    h('div', { class: 'card' },
      h('p', {}, `Přihlášen(a) jako ${me.name} (${me.email})`),
      h('button', { class: 'big', onclick: logout }, 'Odhlásit se')));
}

function adminPanel() {
  const box = h('div', { class: 'card' }, h('h2', {}, 'Správa rodiny'), h('p', { class: 'loading' }, 'Načítám…'));
  rpc('admin_list_members').then(list => fill(box, ...adminContent(list))).catch(() => { });
  return box;
}

function adminContent(list) {
  const nameIn = h('input', { type: 'text', id: 'a-name', placeholder: 'Jméno' });
  const mailIn = h('input', { type: 'email', id: 'a-mail', placeholder: 'e-mail' });
  const adminIn = h('input', { type: 'checkbox' });
  let editing = null;
  const addBtn = h('button', { class: 'primary', type: 'submit' }, 'Přidat');

  const carry = h('input', { type: 'checkbox', checked: true });

  return [
    h('h2', {}, 'Správa rodiny'),
    h('p', { class: 'muted' }, 'Kdo je v seznamu, může se přihlásit svým e-mailem.'),
    list.map(m => h('div', { class: 'member' },
      h('div', {}, m.name, m.is_admin ? ' (správce)' : '', h('small', {}, m.email)),
      h('div', { class: 'row' },
        h('button', {
          onclick: () => {
            editing = m.id; nameIn.value = m.name; mailIn.value = m.email; adminIn.checked = m.is_admin;
            addBtn.textContent = 'Uložit změny'; nameIn.focus();
          },
        }, 'Upravit'),
        m.id !== state.me.id && h('button', {
          class: 'danger',
          onclick: e => {
            if (confirm(`Opravdu odebrat ${m.name}? Smažou se i jeho/její přání a nákupy.`))
              act(e.target, () => rpc('admin_delete_member', { p_id: m.id }), 'Odebráno');
          },
        }, 'Odebrat')))),
    h('form', {
      onsubmit: e => {
        e.preventDefault();
        if (!nameIn.value.trim() || !mailIn.value.trim()) return toast('Vyplň jméno i e-mail.', true);
        act(addBtn, () => rpc('admin_save_member', {
          p_id: editing, p_member_email: mailIn.value, p_name: nameIn.value, p_is_admin: adminIn.checked,
        }), 'Uloženo');
      },
    },
      h('h3', { style: 'margin-top:20px' }, 'Přidat / upravit člena'),
      h('label', { for: 'a-name' }, 'Jméno'), nameIn,
      h('label', { for: 'a-mail' }, 'E-mail'), mailIn,
      h('label', { class: 'check' }, adminIn, h('span', {}, 'Správce (může spravovat rodinu)')),
      addBtn),
    h('h3', { style: 'margin-top:28px' }, `Nový ročník (teď: ${state.year})`),
    h('p', { class: 'muted' }, 'Po Vánocích začni nový rok. Letošní přání zůstanou uložená v archivu.'),
    h('label', { class: 'check' }, carry, h('span', {}, 'Přenést nesplněná přání do nového roku')),
    h('button', {
      class: 'danger',
      onclick: e => {
        if (confirm(`Opravdu začít ročník ${state.year + 1}? Všem se vyprázdní seznam přání.`))
          act(e.target, () => rpc('admin_new_year', { p_carry: carry.checked }), 'Nový ročník začal');
      },
    }, `Začít ročník ${state.year + 1}`),
  ];
}

start();
