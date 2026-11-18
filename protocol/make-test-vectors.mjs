// Independent reference implementation. All secrets here are PUBLIC TEST VALUES.
import { createHash, createHmac, hkdfSync, createCipheriv, createDecipheriv, timingSafeEqual } from 'node:crypto';
import { writeFileSync } from 'node:fs';

const hex = b => Buffer.from(b).toString('hex');
const bytes = s => Buffer.from(s, 'hex');
const cat = (...parts) => Buffer.concat(parts);
const uuidBytes = s => bytes(s.replaceAll('-', ''));
const uuid = b => {
  const s = hex(b).toUpperCase();
  return `${s.slice(0,8)}-${s.slice(8,12)}-${s.slice(12,16)}-${s.slice(16,20)}-${s.slice(20)}`;
};
const sha256Hex = buf => createHash('sha256').update(buf).digest('hex');

const maxFrameBytes = 4 * 1024 * 1024;
const maxTemplates = 300;
const maxTemplateTombstones = 1000;
const tombstoneLifetimeMillis = 180 * 24 * 60 * 60 * 1000;
const maxTemplateTextBytes = 64 * 1024;
const maxTemplateTitleChars = 100;
const maxTemplateTitleBytes = 400;
const maxTemplateTagChars = 30;
const maxTemplateTagBytes = 120;
const maxTemplatePageBodyBytes = 256 * 1024;
const maxTemplatePages = 80;
const maxTemplateTotalBytes = 20 * 1024 * 1024;

const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const ni = Buffer.alloc(32, 0x11), np = Buffer.alloc(32, 0x22);
const padId = '00112233-4455-6677-8899-AABBCCDDEEFF';
const pcId = '10213243-5465-7687-98A9-BACBDCEDFE0F';
const otherPcId = '20314253-6475-8697-A8B9-CADBECFD0E1F';
const id = 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE';
const id2 = '11111111-2222-4333-8444-555555555555';
const op1 = '22222222-3333-4444-8555-666666666666';
const op2 = '33333333-4444-4555-8666-777777777777';
const tplId1 = '44444444-5555-4666-8777-888888888881';
const tplId2 = '44444444-5555-4666-8777-888888888882';
const tplId3 = '44444444-5555-4666-8777-888888888883';
const tplId4 = '44444444-5555-4666-8777-888888888884';
const tplId5 = '44444444-5555-4666-8777-888888888885';
const tplId6 = '44444444-5555-4666-8777-888888888886';
const tombId1 = '55555555-6666-4777-8888-999999999991';
const tombId2 = '55555555-6666-4777-8888-999999999992';

const pcName = '試験 PC: +% / 💻';
const encodeName = s => [...Buffer.from(s)].map(b => /[A-Za-z0-9._~-]/.test(String.fromCharCode(b)) ? String.fromCharCode(b) : `%${b.toString(16).toUpperCase().padStart(2,'0')}`).join('');
const qr = `clipboardplus-pair:1:${uuidBytes(pcId).toString('base64url')}:${key.toString('base64url')}:${encodeName(pcName)}`;
function parsePair(s) {
  const p = s.split(':');
  if (p.length !== 5 || p[0] !== 'clipboardplus-pair' || p[1] !== '1') throw Error('pairing');
  const decode = (v, n) => {
    const b = Buffer.from(v, 'base64url');
    if (!/^[A-Za-z0-9_-]+$/.test(v) || b.length !== n || b.toString('base64url') !== v) throw Error('pairing');
    return b;
  };
  if (!/^(?:[A-Za-z0-9._~-]|%[0-9a-fA-F]{2})+$/.test(p[4])) throw Error('pairing');
  const name = decodeURIComponent(p[4]);
  if (Buffer.byteLength(name) > 255 || /[\u0000-\u001f\u007f]/.test(name)) throw Error('pairing');
  return { pcId: uuid(decode(p[2], 16)), keyHex: hex(decode(p[3], 32)), name };
}

const protocolVersion = 3;
const mac = label => createHmac('sha256', key).update(cat(Buffer.from([protocolVersion]), Buffer.from(label), uuidBytes(pcId), uuidBytes(padId), ni, np)).digest();
const pcHmac = mac('pc'), padHmac = mac('pad');
const hello = cat(bytes('0103'), uuidBytes(padId), ni);
const welcome = cat(bytes('0203'), uuidBytes(pcId), np, pcHmac);
const versionMismatchWelcome = cat(bytes('0203'), uuidBytes(pcId), Buffer.alloc(64));
const versionMismatchSamePc = cat(bytes('0202'), uuidBytes(pcId), Buffer.alloc(64));
const versionMismatchOtherPc = cat(bytes('0202'), uuidBytes(otherPcId), Buffer.alloc(64));
const versionMismatchLegacyZeroId = cat(bytes('0201'), Buffer.alloc(16), Buffer.alloc(64));
const auth = cat(bytes('03'), padHmac);
const keys = Object.fromEntries(['pad->pc','pc->pad'].map(d => [d, Buffer.from(hkdfSync('sha256', key, cat(ni,np), `clipboardplus v3 ${d}`, 32))]));

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .filter(k => value[k] !== undefined)
        .sort((a, b) => a < b ? -1 : a > b ? 1 : 0)
        .map(k => [k, sortKeys(value[k])])
    );
  }
  return value;
}

function plaintext(header, body = '') {
  const json = JSON.stringify(sortKeys(header));
  const h = Buffer.from(json), length = Buffer.alloc(2);
  length.writeUInt16BE(h.length);
  return { headerJson: json, bodyUtf8: typeof body === 'string' ? body : undefined, plaintextHex: hex(cat(length, h, Buffer.from(body))) };
}

function jsonBodyPlaintext(header, bodyObj) {
  const bodyJson = JSON.stringify(sortKeys(bodyObj));
  return plaintext(header, bodyJson);
}

const tinyPNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP+8AAAAASUVORK5CYII=', 'base64');
const messages = {
  item: plaintext({ t:'item', id, kind:'text', at:1794873600123, from:'pad' }, 'こんにちは、Windows！\n2行目: 📋😊\n' + '同期の試験です。'.repeat(8)),
  ack: plaintext({ t:'ack', ids:[id,id2] }),
  ping: plaintext({ t:'ping' }),
  pong: plaintext({ t:'pong' }),
  device: plaintext({ t:'device', kind:'phone' }),
  offer: plaintext({ t:'offer', id:id2, at:1794873600123, from:'pc', kind:'file', size:4,
    sha256:createHash('sha256').update(bytes('0001feff')).digest('hex'), name64:Buffer.from('試験.txt').toString('base64'), type:'public.data' }),
  chunk: plaintext({ t:'chunk', id:id2, offset:0 }, bytes('0001feff')),
  resume: plaintext({ t:'resume', id:id2, offset:2 }),
  continuedChunk: plaintext({ t:'chunk', id:id2, offset:2 }, bytes('feff')),
  imageOffer: plaintext({ t:'offer', id, at:1794873600123, from:'pad', kind:'image', size:tinyPNG.length,
    sha256:createHash('sha256').update(tinyPNG).digest('hex'), name64:'', type:'public.png' }),
  imageChunk: plaintext({ t:'chunk', id, offset:0 }, tinyPNG),
  zwjOffer: plaintext({ t:'offer', id:id2, at:1794873600123, from:'pc', kind:'file', size:4,
    sha256:createHash('sha256').update(bytes('0001feff')).digest('hex'), name64:Buffer.from('家族👨‍👩‍👧‍👦.txt').toString('base64'), type:'public.data' })
};

function frameFromPlaintext(direction, sequence, messageName, sourceMap) {
  const seq = Buffer.alloc(8); seq.writeBigUInt64BE(BigInt(sequence));
  const aad = cat(bytes('10'), seq), nonce = cat(Buffer.alloc(4), seq);
  const cipher = createCipheriv('aes-256-gcm', keys[direction], nonce);
  cipher.setAAD(aad);
  const encrypted = cat(cipher.update(bytes(sourceMap[messageName].plaintextHex)), cipher.final());
  const tag = cipher.getAuthTag(), result = cat(aad, encrypted, tag);
  const decipher = createDecipheriv('aes-256-gcm', keys[direction], nonce);
  decipher.setAAD(aad); decipher.setAuthTag(tag);
  if (hex(cat(decipher.update(encrypted), decipher.final())) !== sourceMap[messageName].plaintextHex) throw Error('roundtrip');
  return { direction, sequence:String(sequence), message: messageName, nonceHex:hex(nonce), aadHex:hex(aad), ciphertextHex:hex(encrypted), tagHex:hex(tag), frameHex:hex(result) };
}
const frame = (direction, sequence, message) => frameFromPlaintext(direction, sequence, message, messages);

// Each direction is one independent session; sequence 0 and 1 never reuse a nonce/key.
const frames = [frame('pad->pc',0,'item'), frame('pad->pc',1,'ping'), frame('pc->pad',0,'ack'), frame('pc->pad',1,'pong'),
  frame('pc->pad',2,'offer'), frame('pc->pad',3,'chunk'), frame('pad->pc',2,'resume')];

function split(frameBytes, limit) {
  const result = [];
  for (let i = 0; i < frameBytes.length; i += limit - 1) {
    const end = Math.min(i + limit - 1, frameBytes.length);
    result.push(hex(cat(Buffer.from([(i === 0 ? 1 : 0) | (end === frameBytes.length ? 2 : 0)]), frameBytes.subarray(i,end))));
  }
  return result;
}
const flipLast = b => { const c = Buffer.from(b); c[c.length - 1] ^= 1; return c; };
const badTag = flipLast(bytes(frames[0].frameHex));
let rejected = false;
try {
  const d = createDecipheriv('aes-256-gcm', keys['pad->pc'], bytes(frames[0].nonceHex));
  d.setAAD(badTag.subarray(0,9)); d.setAuthTag(badTag.subarray(-16));
  d.update(badTag.subarray(9,-16)); d.final();
} catch { rejected = true; }
if (!rejected || timingSafeEqual(pcHmac, flipLast(pcHmac))) throw Error('negative crypto check');

// --- Template Sync Helpers & Independent Merge Reference ---
const graphemeSegmenter = new Intl.Segmenter('en', { granularity: 'grapheme' });
function truncateGraphemesAndBytes(value, maxChars, maxBytes) {
  let out = '', chars = 0, byteLen = 0;
  for (const { segment } of graphemeSegmenter.segment(value)) {
    const segBytes = Buffer.byteLength(segment);
    if (chars + 1 > maxChars || byteLen + segBytes > maxBytes) break;
    out += segment;
    chars += 1;
    byteLen += segBytes;
  }
  return out;
}
function normalizeLabel(value, maxChars, maxBytes) {
  if (value === undefined || value === null) return undefined;
  const trimmed = value.trim();
  if (trimmed.length === 0) return undefined;
  const capped = truncateGraphemesAndBytes(trimmed, maxChars, maxBytes).trim();
  return capped.length === 0 ? undefined : capped;
}
const normalizeTitle = v => normalizeLabel(v, maxTemplateTitleChars, maxTemplateTitleBytes);
const normalizeTag = v => normalizeLabel(v, maxTemplateTagChars, maxTemplateTagBytes);

function contentHash(item) {
  const t = normalizeTitle(item.title) ?? null;
  const g = normalizeTag(item.tag) ?? null;
  return sha256Hex(Buffer.from(JSON.stringify([item.kind, item.text, t, g])));
}

function makeConflictTitle(originalTitle) {
  const norm = normalizeTitle(originalTitle);
  if (norm === undefined) return '別の端末の編集';
  const suffix = '（別の端末の編集）';
  const suffixChars = [...graphemeSegmenter.segment(suffix)].length;
  const suffixBytes = Buffer.byteLength(suffix);
  const prefix = truncateGraphemesAndBytes(norm, maxTemplateTitleChars - suffixChars, maxTemplateTitleBytes - suffixBytes).trimEnd();
  return prefix + suffix;
}

function deterministicConflictId(originalId, loserHash, usedIds) {
  for (let counter = 0; ; counter++) {
    const input = counter === 0
      ? `clipboardplus-tpl-conflict-v1:${originalId.toUpperCase()}:${loserHash}`
      : `clipboardplus-tpl-conflict-v1:${originalId.toUpperCase()}:${loserHash}:${counter}`;
    const digest = createHash('sha256').update(Buffer.from(input, 'utf8')).digest().subarray(0, 16);
    digest[6] = (digest[6] & 0x0F) | 0x40;
    digest[8] = (digest[8] & 0x3F) | 0x80;
    const candidate = uuid(digest);
    if (!usedIds.has(candidate)) {
      usedIds.add(candidate);
      return candidate;
    }
  }
}

function compareScalars(a, b) {
  const ia = a[Symbol.iterator]();
  const ib = b[Symbol.iterator]();
  while (true) {
    const na = ia.next();
    const nb = ib.next();
    if (na.done && nb.done) return 0;
    if (na.done) return -1;
    if (nb.done) return 1;
    const ca = na.value.codePointAt(0);
    const cb = nb.value.codePointAt(0);
    if (ca !== cb) return ca - cb;
  }
}

function cleanItem(item) {
  return sortKeys({
    id: item.id.toUpperCase(),
    kind: item.kind,
    order: item.order,
    tag: normalizeTag(item.tag),
    text: item.text,
    title: normalizeTitle(item.title),
    updatedAt: item.updatedAt,
  });
}

function cleanTombstone(t) {
  return sortKeys({
    baseHash: t.baseHash,
    deletedAt: t.deletedAt,
    id: t.id.toUpperCase(),
  });
}

function mergeTemplates(pc, remote, nowMillis, remoteSentAtMillis = undefined) {
  const clockSkewSeconds = remoteSentAtMillis !== undefined && Math.abs(remoteSentAtMillis - nowMillis) >= 300_000
    ? Math.trunc(Math.abs(remoteSentAtMillis - nowMillis) / 1000)
    : undefined;

  const usedIds = new Set();
  const indexSide = side => {
    const items = new Map();
    const tombs = new Map();
    for (const raw of side.templates) {
      const item = { ...cleanItem(raw), baseHash: raw.baseHash };
      usedIds.add(item.id);
      items.set(item.id, { item, hash: contentHash(item) });
    }
    for (const rawTomb of side.tombstones) {
      const t = cleanTombstone(rawTomb);
      usedIds.add(t.id);
      if (nowMillis - t.deletedAt <= tombstoneLifetimeMillis) tombs.set(t.id, t);
    }
    return { items, tombs };
  };

  const pcIdx = indexSide(pc);
  const remoteIdx = indexSide(remote);
  const allIds = new Set([...pcIdx.items.keys(), ...pcIdx.tombs.keys(), ...remoteIdx.items.keys(), ...remoteIdx.tombs.keys()]);

  const survivingItems = [];
  const survivingTombs = new Map();
  const conflictCandidates = [];

  const mergeTomb = (a, b) => {
    if (a.deletedAt > b.deletedAt) return cleanTombstone({ ...a, baseHash: a.baseHash ?? b.baseHash });
    if (b.deletedAt > a.deletedAt) return cleanTombstone({ ...b, baseHash: b.baseHash ?? a.baseHash });
    const bh = !a.baseHash ? b.baseHash : !b.baseHash ? a.baseHash : (a.baseHash <= b.baseHash ? a.baseHash : b.baseHash);
    return cleanTombstone({ id: a.id, deletedAt: a.deletedAt, baseHash: bh });
  };

  for (const itemId of allIds) {
    const pe = pcIdx.items.get(itemId);
    const re = remoteIdx.items.get(itemId);
    const pt = pcIdx.tombs.get(itemId);
    const rt = remoteIdx.tombs.get(itemId);

    if (pe && re) {
      if (pe.hash === re.hash) {
        const order = re.item.updatedAt > pe.item.updatedAt ? re.item.order
          : pe.item.updatedAt > re.item.updatedAt ? pe.item.order
          : Math.min(pe.item.order, re.item.order);
        const updatedAt = Math.max(pe.item.updatedAt, re.item.updatedAt);
        survivingItems.push({ item: cleanItem({ ...pe.item, order, updatedAt }), hash: pe.hash });
      } else {
        const remoteUnedited = re.item.baseHash !== undefined && re.item.baseHash === re.hash;
        const pcUnedited = re.item.baseHash !== undefined && re.item.baseHash === pe.hash;
        if (remoteUnedited && !pcUnedited) {
          survivingItems.push({ item: cleanItem(pe.item), hash: pe.hash });
        } else if (pcUnedited && !remoteUnedited) {
          survivingItems.push({ item: cleanItem(re.item), hash: re.hash });
        } else {
          let winner, loser;
          if (pe.item.updatedAt > re.item.updatedAt) { winner = pe; loser = re; }
          else if (re.item.updatedAt > pe.item.updatedAt) { winner = re; loser = pe; }
          else if (pe.hash <= re.hash) { winner = pe; loser = re; }
          else { winner = re; loser = pe; }
          survivingItems.push({ item: cleanItem(winner.item), hash: winner.hash });
          if (winner.item.text !== loser.item.text) {
            conflictCandidates.push({ originalId: winner.item.id, loser: cleanItem(loser.item), loserHash: loser.hash });
          }
        }
      }
    } else if ((pe && rt) || (re && pt)) {
      const survivor = pe ?? re;
      const tomb = rt ?? pt;
      const unedited = (survivor.item.baseHash !== undefined && survivor.item.baseHash === survivor.hash) ||
        (tomb.baseHash !== undefined && tomb.baseHash === survivor.hash);
      if (unedited) {
        survivingTombs.set(tomb.id, cleanTombstone({ ...tomb, baseHash: tomb.baseHash ?? survivor.hash }));
      } else {
        survivingItems.push({ item: cleanItem(survivor.item), hash: survivor.hash });
      }
    } else if (pe) {
      survivingItems.push({ item: cleanItem(pe.item), hash: pe.hash });
    } else if (re) {
      survivingItems.push({ item: cleanItem(re.item), hash: re.hash });
    } else if (pt && rt) {
      survivingTombs.set(itemId, mergeTomb(pt, rt));
    } else if (pt) {
      survivingTombs.set(itemId, pt);
    } else if (rt) {
      survivingTombs.set(itemId, rt);
    }
  }

  // Deduplicate same text
  const byText = new Map();
  for (const e of survivingItems) {
    if (!byText.has(e.item.text)) byText.set(e.item.text, []);
    byText.get(e.item.text).push(e);
  }
  const deduped = [];
  let subsumedDuplicateCount = 0;
  for (const grp of byText.values()) {
    grp.sort((a, b) => (a.item.updatedAt !== b.item.updatedAt ? b.item.updatedAt - a.item.updatedAt : (a.item.id < b.item.id ? -1 : a.item.id > b.item.id ? 1 : 0)));
    const primary = { ...grp[0].item };
    for (let i = 1; i < grp.length; i++) {
      const other = grp[i];
      if (primary.title === undefined && other.item.title !== undefined) primary.title = other.item.title;
      if (primary.tag === undefined && other.item.tag !== undefined) primary.tag = other.item.tag;
      const t = cleanTombstone({ id: other.item.id, deletedAt: nowMillis, baseHash: other.hash });
      survivingTombs.set(t.id, survivingTombs.has(t.id) ? mergeTomb(survivingTombs.get(t.id), t) : t);
      subsumedDuplicateCount++;
    }
    const merged = cleanItem(primary);
    deduped.push({ item: merged, hash: contentHash(merged) });
  }

  const activeTexts = new Set(deduped.map(x => x.item.text));
  const conflictCopies = [];
  conflictCandidates.sort((a, b) => {
    if (a.loser.updatedAt !== b.loser.updatedAt) return a.loser.updatedAt - b.loser.updatedAt;
    if (a.loserHash !== b.loserHash) return a.loserHash < b.loserHash ? -1 : 1;
    return a.originalId < b.originalId ? -1 : a.originalId > b.originalId ? 1 : 0;
  });
  for (const c of conflictCandidates) {
    if (activeTexts.has(c.loser.text)) continue;
    activeTexts.add(c.loser.text);
    const newId = deterministicConflictId(c.originalId, c.loserHash, usedIds);
    conflictCopies.push(cleanItem({
      id: newId,
      kind: c.loser.kind,
      text: c.loser.text,
      title: makeConflictTitle(c.loser.title),
      tag: undefined,
      order: Number.MAX_SAFE_INTEGER,
      updatedAt: c.loser.updatedAt,
    }));
  }

  const byTag = new Map();
  const untagged = [];
  for (const { item } of deduped) {
    if (item.tag === undefined) untagged.push({ item, isConflict: false });
    else {
      if (!byTag.has(item.tag)) byTag.set(item.tag, []);
      byTag.get(item.tag).push({ item, isConflict: false });
    }
  }
  for (const copy of conflictCopies) untagged.push({ item: copy, isConflict: true });

  const templates = [];
  const appendGroup = group => {
    group.sort((a, b) => {
      if (a.isConflict !== b.isConflict) return a.isConflict ? 1 : -1;
      if (a.item.order !== b.item.order) return a.item.order - b.item.order;
      if (a.item.updatedAt !== b.item.updatedAt) return a.item.updatedAt - b.item.updatedAt;
      return a.item.id < b.item.id ? -1 : a.item.id > b.item.id ? 1 : 0;
    });
    group.forEach((g, idx) => templates.push(cleanItem({ ...g.item, order: idx })));
  };
  for (const tag of [...byTag.keys()].sort(compareScalars)) appendGroup(byTag.get(tag));
  appendGroup(untagged);

  let tombstones = [...survivingTombs.values()]
    .filter(t => nowMillis - t.deletedAt <= tombstoneLifetimeMillis)
    .sort((a, b) => (a.deletedAt !== b.deletedAt ? a.deletedAt - b.deletedAt : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)));
  if (tombstones.length > maxTemplateTombstones) tombstones = tombstones.slice(-maxTemplateTombstones);

  const computeChanges = (beforeMap, after) => {
    const afterMap = new Map(after.map(i => [i.id, i]));
    let added = 0, updated = 0, deleted = 0;
    for (const [itemId, afterItem] of afterMap) {
      const beforeEntry = beforeMap.get(itemId);
      if (!beforeEntry) added++;
      else {
        const b = beforeEntry.item;
        if (b.kind !== afterItem.kind || b.text !== afterItem.text || b.title !== afterItem.title ||
            b.tag !== afterItem.tag || b.order !== afterItem.order) updated++;
      }
    }
    for (const itemId of beforeMap.keys()) if (!afterMap.has(itemId)) deleted++;
    return { added, updated, deleted };
  };

  return sortKeys({
    templates,
    tombstones,
    conflictCopyCount: conflictCopies.length,
    subsumedDuplicateCount,
    pcChanges: computeChanges(pcIdx.items, templates),
    remoteChanges: computeChanges(remoteIdx.items, templates),
    clockSkewSeconds,
  });
}

// --- Template Wire Messages ---
const sampleTpl1 = {
  id: tplId1,
  kind: 'text',
  text: 'お世話になっております。\nよろしくお願いいたします。📋\n家族👨‍👩‍👧‍👦',
  title: '挨拶定型文',
  tag: '仕事',
  order: 0,
  updatedAt: 1794873500000,
};
sampleTpl1.baseHash = contentHash(sampleTpl1);

const sampleTpl2 = {
  id: tplId2,
  kind: 'url',
  text: 'https://example.com/path?a=1&b=2',
  title: '家族👨‍👩‍👧‍👦のリンク',
  order: 0,
  updatedAt: 1794873550000,
};

const sampleTomb1 = { id: tombId1, deletedAt: 1794873400000, baseHash: sha256Hex(Buffer.from('deleted-1')) };
const sampleTomb2 = { id: tombId2, deletedAt: 1794873450000 };

const templateMessages = {
  tplPull: plaintext({ t: 'tpl_pull', op: op1 }),
  tplPushSingle: jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1,
    sentAt: 1794873600500,
    templates: [sampleTpl1, sampleTpl2],
    tombstones: [sampleTomb1, sampleTomb2],
  }),
  tplPushPage0: jsonBodyPlaintext({ t: 'tpl_push', op: op2, part: 0, total: 2 }, {
    v: 1,
    sentAt: 1794873600600,
    templates: [sampleTpl1],
    tombstones: [],
  }),
  tplPushPage1: jsonBodyPlaintext({ t: 'tpl_push', op: op2, part: 1, total: 2 }, {
    templates: [sampleTpl2],
    tombstones: [sampleTomb1],
  }),
  tplState: jsonBodyPlaintext({ t: 'tpl_state', op: op1, part: 0, total: 1 }, {
    v: 1,
    sentAt: 1794873601000,
    templates: [cleanItem(sampleTpl1), cleanItem(sampleTpl2)],
    tombstones: [sampleTomb1, sampleTomb2],
  }),
  tplAck: plaintext({ t: 'tpl_ack', op: op1 }),
};

// Independent sequence starting at 0 per direction for templateFrames.
const templateFrames = [
  frameFromPlaintext('pc->pad', 0, 'tplPull', templateMessages),
  frameFromPlaintext('pad->pc', 0, 'tplPushSingle', templateMessages),
  frameFromPlaintext('pad->pc', 1, 'tplPushPage0', templateMessages),
  frameFromPlaintext('pad->pc', 2, 'tplPushPage1', templateMessages),
  frameFromPlaintext('pc->pad', 1, 'tplState', templateMessages),
  frameFromPlaintext('pad->pc', 3, 'tplAck', templateMessages),
];

const templateFragmentation = [20, 182, 512].map(packetLimit => ({
  frameIndex: 1,
  packetLimit,
  packetsHex: split(bytes(templateFrames[1].frameHex), packetLimit),
}));

const templateFailures = {
  controlTitleTemplate: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'abc', title: 'bad\u0007title', order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'format' },
  newlineTitleTemplate: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'abc', title: 'line1\nline2', order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'format' },
  controlTagTemplate: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'abc', tag: 'bad\u0085tag', order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'format' },
  oversizedTitleChars: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'abc', title: 'あ'.repeat(101), order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'limit' },
  oversizedTitleBytes: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'abc', title: '👨‍👩‍👧‍👦'.repeat(20), order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'limit' },
  oversizedTagChars: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'abc', tag: 'あ'.repeat(31), order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'limit' },
  oversizedTagBytes: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'abc', tag: '👨‍👩‍👧‍👦'.repeat(5), order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'limit' },
  invalidPartEqualTotal: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 1, total: 1 }, {
    templates: [], tombstones: [],
  }), error: 'format' },
  zeroTotalPages: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 0 }, {
    v: 1, sentAt: 1794873600000, templates: [], tombstones: [],
  }), error: 'format' },
  tooManyTotalPages: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 81 }, {
    v: 1, sentAt: 1794873600000, templates: [], tombstones: [],
  }), error: 'limit' },
  duplicateTemplateId: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [
      { id: tplId1, kind: 'text', text: 'a', order: 0, updatedAt: 1 },
      { id: tplId1, kind: 'text', text: 'b', order: 1, updatedAt: 2 },
    ],
    tombstones: [],
  }), error: 'format' },
  duplicateTombstoneId: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [],
    tombstones: [
      { id: tombId1, deletedAt: 1 },
      { id: tombId1, deletedAt: 2 },
    ],
  }), error: 'format' },
  templateAndTombstoneSameId: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'a', order: 0, updatedAt: 1 }],
    tombstones: [{ id: tplId1, deletedAt: 2 }],
  }), error: 'format' },
  tplStateWithTemplateBaseHash: { ...jsonBodyPlaintext({ t: 'tpl_state', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'a', order: 0, updatedAt: 1, baseHash: sha256Hex(Buffer.from('x')) }],
    tombstones: [],
  }), error: 'format' },
  tplPullWithBody: { ...plaintext({ t: 'tpl_pull', op: op1 }, '{}'), error: 'format' },
  tplAckWithBody: { ...plaintext({ t: 'tpl_ack', op: op1 }, '{}'), error: 'format' },
  part0MissingVersion: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    sentAt: 1794873600000, templates: [], tombstones: [],
  }), error: 'format' },
  part1WithSentAt: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op2, part: 1, total: 2 }, {
    sentAt: 1794873600000, templates: [], tombstones: [],
  }), error: 'format' },
  badBaseHash: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'a', order: 0, updatedAt: 1, baseHash: 'A'.repeat(64) }],
    tombstones: [],
  }), error: 'format' },
  badKind: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'image', text: 'a', order: 0, updatedAt: 1 }],
    tombstones: [],
  }), error: 'format' },
  negativeOrder: { ...jsonBodyPlaintext({ t: 'tpl_push', op: op1, part: 0, total: 1 }, {
    v: 1, sentAt: 1794873600000,
    templates: [{ id: tplId1, kind: 'text', text: 'a', order: -1, updatedAt: 1 }],
    tombstones: [],
  }), error: 'format' },
  oversizedTemplateText: { textBytes: maxTemplateTextBytes + 1, error: 'limit', note: 'Materialize oversized text locally.' },
  tooManyTemplates: { count: maxTemplates + 1, error: 'limit', note: 'Materialize 301 templates locally.' },
  tooManyTombstones: { count: maxTemplateTombstones + 1, error: 'limit', note: 'Materialize 1001 tombstones locally.' },
  oversizedPageBody: { bodyBytes: maxTemplatePageBodyBytes + 1, error: 'limit', note: 'Materialize >256KiB page body locally.' },
};

// --- Merge Test Cases ---
const baseNow = 1794873600000;
function makeMergeCase(name, nowMillis, pc, remote, opts = {}) {
  const expected = mergeTemplates(pc, remote, nowMillis, opts.remoteSentAtMillis);
  if (opts.alsoCheckCommutative) {
    const swapped = mergeTemplates(remote, pc, nowMillis, opts.remoteSentAtMillis);
    if (JSON.stringify(swapped.templates) !== JSON.stringify(expected.templates) ||
        JSON.stringify(swapped.tombstones) !== JSON.stringify(expected.tombstones)) {
      throw Error(`commutativity failed for ${name}`);
    }
  }
  if (opts.alsoCheckIdempotent) {
    const pc2 = { templates: expected.templates, tombstones: expected.tombstones };
    const remote2 = {
      templates: expected.templates.map(t => ({ ...t, baseHash: contentHash(t) })),
      tombstones: expected.tombstones,
    };
    const resync = mergeTemplates(pc2, remote2, nowMillis + 1000, nowMillis + 1000);
    if (resync.pcChanges.added + resync.pcChanges.updated + resync.pcChanges.deleted !== 0 ||
        resync.remoteChanges.added + resync.remoteChanges.updated + resync.remoteChanges.deleted !== 0 ||
        resync.conflictCopyCount !== 0 || resync.subsumedDuplicateCount !== 0) {
      throw Error(`idempotency failed for ${name}`);
    }
  }
  return sortKeys({
    name,
    nowMillis,
    remoteSentAtMillis: opts.remoteSentAtMillis,
    pc: sortKeys(pc),
    remote: sortKeys(remote),
    alsoCheckCommutative: opts.alsoCheckCommutative || undefined,
    alsoCheckIdempotent: opts.alsoCheckIdempotent || undefined,
    expected,
  });
}

const h1Init = contentHash({ kind: 'text', text: '初期1' });
const h2Init = contentHash({ kind: 'text', text: '旧文2' });
const h3Del = contentHash({ kind: 'text', text: '消す3' });
const h4Del = contentHash({ kind: 'text', text: '消す4' });
const hClock1 = contentHash({ kind: 'text', text: '時計前' });
const hClock2 = contentHash({ kind: 'text', text: '時計削除' });
const hClock3 = contentHash({ kind: 'text', text: '時計PC残' });
const hClock4 = contentHash({ kind: 'text', text: '並替A' });
const hClock5 = contentHash({ kind: 'text', text: '並替B' });
const hBoth = contentHash({ kind: 'text', text: '元の本文', title: '元の題', tag: '仕事' });
const hBoth2 = contentHash({ kind: 'text', text: '元の本文2', tag: 'メモ' });
const hMeta = contentHash({ kind: 'text', text: '共通本文', title: '元題', tag: '元タグ' });
const hDelEdit = contentHash({ kind: 'text', text: '削除前' });
const hEq = contentHash({ kind: 'text', text: '同時元', title: 'T', tag: 'T' });

const templateMergeCases = [
  makeMergeCase('singleSideAddEditDelete', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: 'PC編集後', order: 0, updatedAt: baseNow - 80_000 },
      { id: tplId2, kind: 'text', text: '旧文2', order: 1, updatedAt: baseNow - 100_000 },
      { id: tplId4, kind: 'text', text: '消す4', order: 2, updatedAt: baseNow - 100_000 },
      { id: tplId5, kind: 'text', text: 'PC新規', order: 3, updatedAt: baseNow - 70_000 },
    ],
    tombstones: [
      { id: tplId3, deletedAt: baseNow - 60_000, baseHash: h3Del },
    ],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: '初期1', order: 0, updatedAt: baseNow - 100_000, baseHash: h1Init },
      { id: tplId2, kind: 'text', text: '端末編集後', order: 1, updatedAt: baseNow - 50_000, baseHash: h2Init },
      { id: tplId3, kind: 'text', text: '消す3', order: 2, updatedAt: baseNow - 100_000, baseHash: h3Del },
      { id: tplId6, kind: 'url', text: 'https://example.com', title: '新規URL', order: 3, updatedAt: baseNow - 40_000 },
    ],
    tombstones: [
      { id: tplId4, deletedAt: baseNow - 55_000, baseHash: h4Del },
    ],
  }),

  makeMergeCase('clockSkewedDevice', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: '時計前', order: 0, updatedAt: baseNow - 100_000 },
      { id: tplId3, kind: 'text', text: '時計PC残', order: 1, updatedAt: baseNow - 100_000 },
      { id: tplId4, kind: 'text', text: '並替A', order: 2, updatedAt: baseNow - 100_000 },
      { id: tplId5, kind: 'text', text: '並替B', order: 3, updatedAt: baseNow - 100_000 },
    ],
    tombstones: [
      { id: tplId2, deletedAt: baseNow - 100_000, baseHash: hClock2 },
    ],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: '時計遅れ端末が編集', order: 0, updatedAt: baseNow - 3_600_000, baseHash: hClock1 },
      { id: tplId2, kind: 'text', text: '時計削除', order: 1, updatedAt: baseNow - 50_000, baseHash: hClock2 },
      { id: tplId5, kind: 'text', text: '並替B', order: 2, updatedAt: baseNow - 99_999, baseHash: hClock5 },
      { id: tplId4, kind: 'text', text: '並替A', order: 3, updatedAt: baseNow - 99_999, baseHash: hClock4 },
    ],
    tombstones: [
      { id: tplId3, deletedAt: baseNow - 3_600_000, baseHash: hClock3 },
    ],
  }, { remoteSentAtMillis: baseNow - 3_600_000 }),

  makeMergeCase('bothEditedDifferentTextConflict', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: 'PCの新本文', title: '案件A', tag: '仕事', order: 0, updatedAt: baseNow - 50_000 },
      { id: tplId2, kind: 'text', text: 'PC無題本文', tag: 'メモ', order: 0, updatedAt: baseNow - 80_000 },
      { id: tplId3, kind: 'text', text: '既存のその他', order: 0, updatedAt: baseNow - 100_000 },
    ],
    tombstones: [],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: '端末の別本文', title: '端末案', tag: '仕事', order: 0, updatedAt: baseNow - 70_000, baseHash: hBoth },
      { id: tplId2, kind: 'text', text: '端末新本文', tag: 'メモ', order: 0, updatedAt: baseNow - 40_000, baseHash: hBoth2 },
      { id: tplId3, kind: 'text', text: '既存のその他', order: 0, updatedAt: baseNow - 100_000, baseHash: contentHash({ kind: 'text', text: '既存のその他' }) },
    ],
    tombstones: [],
  }),

  makeMergeCase('bothEditedSameTextMetadataConflict', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: '共通本文', title: '新しい名前', tag: '新タグ', order: 0, updatedAt: baseNow - 30_000 },
    ],
    tombstones: [],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: '共通本文', title: '古い名前', tag: '旧タグ', order: 0, updatedAt: baseNow - 50_000, baseHash: hMeta },
    ],
    tombstones: [],
  }),

  makeMergeCase('deleteVsUnsyncedEdit', baseNow, {
    templates: [
      { id: tplId2, kind: 'text', text: 'PC編集生存', order: 0, updatedAt: baseNow - 60_000 },
    ],
    tombstones: [
      { id: tplId1, deletedAt: baseNow - 40_000, baseHash: hDelEdit },
    ],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: '端末編集生存', order: 0, updatedAt: baseNow - 65_000, baseHash: hDelEdit },
    ],
    tombstones: [
      { id: tplId2, deletedAt: baseNow - 35_000, baseHash: hDelEdit },
    ],
  }),

  makeMergeCase('equalTimestampTieBreakAndCommutative', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: 'alpha', title: 'A', tag: 'T', order: 0, updatedAt: baseNow - 50_000, baseHash: hEq },
    ],
    tombstones: [],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: 'beta', title: 'B', tag: 'T', order: 0, updatedAt: baseNow - 50_000, baseHash: hEq },
    ],
    tombstones: [],
  }, { alsoCheckCommutative: true }),

  makeMergeCase('initialSyncDeduplicatesSameText', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: '同じ定型文', tag: '連絡', order: 0, updatedAt: baseNow - 50_000 },
      { id: tplId3, kind: 'text', text: '時刻優先', title: '新しい方', order: 0, updatedAt: baseNow - 30_000 },
    ],
    tombstones: [],
  }, {
    templates: [
      { id: tplId2, kind: 'text', text: '同じ定型文', title: '定型挨拶', order: 0, updatedAt: baseNow - 50_000 },
      { id: tplId4, kind: 'text', text: '時刻優先', title: '古い方', tag: '補足', order: 0, updatedAt: baseNow - 80_000 },
    ],
    tombstones: [],
  }),

  makeMergeCase('reorderAndTailAppendRenumbering', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: '項目1', tag: '仕事', order: 0, updatedAt: baseNow - 100_000 },
      { id: tplId2, kind: 'text', text: '項目2', tag: '仕事', order: 1, updatedAt: baseNow - 100_000 },
      { id: tplId4, kind: 'text', text: 'PC末尾', tag: '仕事', order: 2, updatedAt: baseNow - 50_000 },
    ],
    tombstones: [],
  }, {
    templates: [
      { id: tplId2, kind: 'text', text: '項目2', tag: '仕事', order: 0, updatedAt: baseNow - 80_000, baseHash: contentHash({ kind: 'text', text: '項目2', tag: '仕事' }) },
      { id: tplId1, kind: 'text', text: '項目1', tag: '仕事', order: 1, updatedAt: baseNow - 80_000, baseHash: contentHash({ kind: 'text', text: '項目1', tag: '仕事' }) },
      { id: tplId3, kind: 'text', text: '端末末尾', tag: '仕事', order: 2, updatedAt: baseNow - 60_000 },
    ],
    tombstones: [],
  }),

  makeMergeCase('idempotentResync', baseNow, {
    templates: [
      { id: tplId1, kind: 'text', text: '安定A', title: 'A', tag: '仕事', order: 0, updatedAt: 1000 },
      { id: tplId2, kind: 'url', text: 'https://example.com', order: 0, updatedAt: 1100 },
    ],
    tombstones: [
      { id: tombId1, deletedAt: baseNow - 10_000, baseHash: h1Init },
    ],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: '安定A', title: 'A', tag: '仕事', order: 0, updatedAt: 1000, baseHash: contentHash({ kind: 'text', text: '安定A', title: 'A', tag: '仕事' }) },
      { id: tplId2, kind: 'url', text: 'https://example.com', order: 0, updatedAt: 1100, baseHash: contentHash({ kind: 'url', text: 'https://example.com' }) },
    ],
    tombstones: [
      { id: tombId1, deletedAt: baseNow - 10_000, baseHash: h1Init },
    ],
  }, { alsoCheckIdempotent: true }),

  makeMergeCase('expiredTombstoneAllowsResurrection', baseNow, {
    templates: [],
    tombstones: [
      { id: tplId1, deletedAt: baseNow - tombstoneLifetimeMillis - 1, baseHash: h1Init },
      { id: tplId2, deletedAt: baseNow - tombstoneLifetimeMillis, baseHash: h2Init },
    ],
  }, {
    templates: [
      { id: tplId1, kind: 'text', text: '初期1', order: 0, updatedAt: 1000, baseHash: h1Init },
      { id: tplId2, kind: 'text', text: '旧文2', order: 1, updatedAt: 1000, baseHash: h2Init },
    ],
    tombstones: [],
  }),
];

const vectors = {
  version: protocolVersion,
  warning: 'PUBLIC deterministic test secrets. Never use for real pairing or connections.',
  limits: {
    maxFrameBytes, maxHeaderBytes: 65535, maxNameUtf8Bytes: 255, maxAckIds: 1024,
    maxItemBytes: 10*1024*1024, chunkBytes: 32768, maxPending: 100, pendingHours: 24,
    duplicateMinutes: 10, maxHistory: 300,
    maxTemplates, maxTemplateTombstones, templateTombstoneDays: 180,
    maxTemplateTextBytes, maxTemplateTitleChars, maxTemplateTitleUtf8Bytes: maxTemplateTitleBytes,
    maxTemplateTagChars, maxTemplateTagUtf8Bytes: maxTemplateTagBytes,
    maxTemplatePageBodyBytes, maxTemplatePages, maxTemplateTotalBytes,
  },
  pairing: { qr, parsed: parsePair(qr) },
  handshake: {
    keyHex: hex(key), padId, pcId, niHex: hex(ni), npHex: hex(np),
    helloHex: hex(hello), welcomeHex: hex(welcome), versionMismatchWelcomeHex: hex(versionMismatchWelcome),
    authHex: hex(auth), pcHmacHex: hex(pcHmac), padHmacHex: hex(padHmac),
    padToPcKeyHex: hex(keys['pad->pc']), pcToPadKeyHex: hex(keys['pc->pad']),
  },
  messages,
  frames,
  fragmentation: [20,182,512].map(packetLimit => ({ frameIndex: 0, packetLimit, packetsHex: split(bytes(frames[0].frameHex), packetLimit) })),
  failures: {
    tamperedTag: { direction: 'pad->pc', frameHex: hex(badTag), error: 'authentication' },
    rollback: { direction: 'pad->pc', framesHex: [frames[1].frameHex, frames[0].frameHex], error: 'sequence' },
    welcomeHmac: { frameHex: hex(flipLast(welcome)), error: 'authentication' },
    versionMismatchSamePc: { frameHex: hex(versionMismatchSamePc), error: 'version' },
    versionMismatchOtherPc: { frameHex: hex(versionMismatchOtherPc), error: 'identity' },
    versionMismatchLegacyZeroId: { frameHex: hex(versionMismatchLegacyZeroId), error: 'identity' },
    authHmac: { frameHex: hex(flipLast(auth)), error: 'authentication' },
    oversizedFrame: { byteLength: maxFrameBytes + 1, fillByte: 0, packetLimit: 182, error: 'limit', note: 'Materialize repeated fillByte locally; no multi-megabyte hex fixture.' },
    unfinishedStart: { packetsHex: ['010102'], finish: true, error: 'packet' },
    continuationWithoutStart: { packetsHex: ['000102'], finish: false, error: 'packet' },
    controlNameOffer: { ...plaintext({ t: 'offer', id: id2, at: 1794873600123, from: 'pc', kind: 'file', size: 4,
      sha256: createHash('sha256').update(bytes('0001feff')).digest('hex'), name64: Buffer.from('bad\u0007.txt').toString('base64'), type: 'public.data' }), error: 'format' },
  },
  templateMessages,
  templateFrames,
  templateFragmentation,
  templateFailures,
  templateMergeCases,
};

writeFileSync(new URL('./test-vectors.json', import.meta.url), JSON.stringify(vectors, null, 2) + '\n');
console.log(`Generated v${protocolVersion}: ${frames.length} frames, ${Object.keys(messages).length} messages, ${templateFrames.length} templateFrames, ${Object.keys(templateMessages).length} templateMessages, ${templateMergeCases.length} templateMergeCases; self-checks passed.`);
