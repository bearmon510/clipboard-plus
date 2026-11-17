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
const maxFrameBytes = 4 * 1024 * 1024;
const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
const ni = Buffer.alloc(32, 0x11), np = Buffer.alloc(32, 0x22);
const padId = '00112233-4455-6677-8899-AABBCCDDEEFF';
const pcId = '10213243-5465-7687-98A9-BACBDCEDFE0F';
const otherPcId = '20314253-6475-8697-A8B9-CADBECFD0E1F';
const id = 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE';
const id2 = '11111111-2222-4333-8444-555555555555';
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
const mac = label => createHmac('sha256', key).update(cat(bytes("02"), Buffer.from(label), uuidBytes(pcId), uuidBytes(padId), ni, np)).digest();
const pcHmac = mac('pc'), padHmac = mac('pad');
const hello = cat(bytes('0102'), uuidBytes(padId), ni);
const welcome = cat(bytes('0202'), uuidBytes(pcId), np, pcHmac);
const versionMismatchWelcome = cat(bytes('0202'), uuidBytes(pcId), Buffer.alloc(64));
const versionMismatchSamePc = cat(bytes('0203'), uuidBytes(pcId), Buffer.alloc(64));
const versionMismatchOtherPc = cat(bytes('0203'), uuidBytes(otherPcId), Buffer.alloc(64));
const versionMismatchLegacyZeroId = cat(bytes('0201'), Buffer.alloc(16), Buffer.alloc(64));
const auth = cat(bytes('03'), padHmac);
const keys = Object.fromEntries(['pad->pc','pc->pad'].map(d => [d, Buffer.from(hkdfSync('sha256', key, cat(ni,np), `clipboardplus v2 ${d}`, 32))]));
function plaintext(header, body = '') {
  const json = JSON.stringify(Object.fromEntries(Object.entries(header).sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0)));
  const h = Buffer.from(json), length = Buffer.alloc(2);
  length.writeUInt16BE(h.length);
  return { headerJson: json, bodyUtf8: body, plaintextHex: hex(cat(length, h, Buffer.from(body))) };
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
function frame(direction, sequence, message) {
  const seq = Buffer.alloc(8); seq.writeBigUInt64BE(BigInt(sequence));
  const aad = cat(bytes('10'), seq), nonce = cat(Buffer.alloc(4), seq);
  const cipher = createCipheriv('aes-256-gcm', keys[direction], nonce);
  cipher.setAAD(aad);
  const encrypted = cat(cipher.update(bytes(messages[message].plaintextHex)), cipher.final());
  const tag = cipher.getAuthTag(), result = cat(aad, encrypted, tag);
  const decipher = createDecipheriv('aes-256-gcm', keys[direction], nonce);
  decipher.setAAD(aad); decipher.setAuthTag(tag);
  if (hex(cat(decipher.update(encrypted), decipher.final())) !== messages[message].plaintextHex) throw Error('roundtrip');
  return { direction, sequence:String(sequence), message, nonceHex:hex(nonce), aadHex:hex(aad), ciphertextHex:hex(encrypted), tagHex:hex(tag), frameHex:hex(result) };
}
// Each direction is one independent session; sequence 0 and 1 never reuse a nonce/key.
const frames = [frame('pad->pc',0,'item'), frame('pad->pc',1,'ping'), frame('pc->pad',0,'ack'), frame('pc->pad',1,'pong'),
  frame('pc->pad',2,'offer'), frame('pc->pad',3,'chunk'), frame('pad->pc',2,'resume')];
function split(frame, limit) {
  const result = [];
  for (let i = 0; i < frame.length; i += limit - 1) {
    const end = Math.min(i + limit - 1, frame.length);
    result.push(hex(cat(Buffer.from([(i === 0 ? 1 : 0) | (end === frame.length ? 2 : 0)]), frame.subarray(i,end))));
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
const vectors = {
  version:2, warning:'PUBLIC deterministic test secrets. Never use for real pairing or connections.',
  limits:{ maxFrameBytes, maxHeaderBytes:65535, maxNameUtf8Bytes:255, maxAckIds:1024, maxItemBytes:10*1024*1024, chunkBytes:32768, maxPending:100, pendingHours:24, duplicateMinutes:10, maxHistory:300 },
  pairing:{ qr, parsed:parsePair(qr) },
  handshake:{ keyHex:hex(key), padId, pcId, niHex:hex(ni), npHex:hex(np), helloHex:hex(hello), welcomeHex:hex(welcome), versionMismatchWelcomeHex:hex(versionMismatchWelcome), authHex:hex(auth), pcHmacHex:hex(pcHmac), padHmacHex:hex(padHmac), padToPcKeyHex:hex(keys['pad->pc']), pcToPadKeyHex:hex(keys['pc->pad']) },
  messages, frames,
  fragmentation:[20,182,512].map(packetLimit => ({ frameIndex:0, packetLimit, packetsHex:split(bytes(frames[0].frameHex),packetLimit) })),
  failures:{
    tamperedTag:{ direction:'pad->pc', frameHex:hex(badTag), error:'authentication' },
    rollback:{ direction:'pad->pc', framesHex:[frames[1].frameHex,frames[0].frameHex], error:'sequence' },
    welcomeHmac:{ frameHex:hex(flipLast(welcome)), error:'authentication' },
    versionMismatchSamePc:{ frameHex:hex(versionMismatchSamePc), error:'version' },
    versionMismatchOtherPc:{ frameHex:hex(versionMismatchOtherPc), error:'identity' },
    versionMismatchLegacyZeroId:{ frameHex:hex(versionMismatchLegacyZeroId), error:'identity' },
    authHmac:{ frameHex:hex(flipLast(auth)), error:'authentication' },
    oversizedFrame:{ byteLength:maxFrameBytes+1, fillByte:0, packetLimit:182, error:'limit', note:'Materialize repeated fillByte locally; no multi-megabyte hex fixture.' },
    unfinishedStart:{ packetsHex:['010102'], finish:true, error:'packet' },
    continuationWithoutStart:{ packetsHex:['000102'], finish:false, error:'packet' },
    controlNameOffer:{ ...plaintext({ t:'offer', id:id2, at:1794873600123, from:'pc', kind:'file', size:4,
      sha256:createHash('sha256').update(bytes('0001feff')).digest('hex'), name64:Buffer.from('bad\u0007.txt').toString('base64'), type:'public.data' }), error:'format' }
  }
};
writeFileSync(new URL('./test-vectors.json',import.meta.url), JSON.stringify(vectors,null,2)+'\n');
console.log(`Generated ${frames.length} frames, ${Object.keys(messages).length} messages, 3 packet limits; crypto self-checks passed.`);
