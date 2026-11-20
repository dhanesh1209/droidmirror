// Generates protocol/test-vectors.json with Node's crypto (an implementation independent of the Swift and Kotlin code).
// Run: node protocol/gen-vectors.mjs > protocol/test-vectors.json
// All values are synthetic and fixed. Never use them as real keys.
import { createHmac, createCipheriv } from "node:crypto";

const bytes = (start, n) => Buffer.from(Array.from({ length: n }, (_, i) => (start + i) & 0xff));
const secret = bytes(0x00, 32);
const macSalt = bytes(0x10, 16);
const phoneSalt = bytes(0x20, 16);
const salt = Buffer.concat([macSalt, phoneSalt]);

const key = (label) => createHmac("sha256", secret).update(Buffer.concat([Buffer.from(label, "utf8"), salt])).digest();

function frame(label, seq, payload, nonce) {
  const seqBuf = Buffer.alloc(8);
  seqBuf.writeBigUInt64BE(BigInt(seq));
  const plaintext = Buffer.concat([seqBuf, Buffer.from(payload, "utf8")]);
  const cipher = createCipheriv("aes-256-gcm", key(label), nonce);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const body = Buffer.concat([nonce, ct, cipher.getAuthTag()]);
  const len = Buffer.alloc(4);
  len.writeUInt32BE(body.length);
  return { label, seq, payload, nonce: nonce.toString("hex"), body: body.toString("hex"), frame: Buffer.concat([len, body]).toString("hex") };
}

const out = {
  secret: secret.toString("hex"),
  macSalt: macSalt.toString("hex"),
  phoneSalt: phoneSalt.toString("hex"),
  keys: { "mac->phone": key("mac->phone").toString("hex"), "phone->mac": key("phone->mac").toString("hex") },
  frames: [
    frame("mac->phone", 1, '{"type":"ping"}', bytes(0xa0, 12)),
    frame("phone->mac", 1, '{"type":"hello","name":"test-phone"}', bytes(0xb0, 12)),
    frame("phone->mac", 2, '{"type":"notification","key":"k1","pkg":"com.example","title":"T","text":"Hi"}', bytes(0xc0, 12)),
  ],
};
console.log(JSON.stringify(out, null, 2));
