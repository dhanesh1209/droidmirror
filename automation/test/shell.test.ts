import { test } from "node:test";
import assert from "node:assert/strict";
import { KEYS, assertInt, assertPackage, keyCode, shellQuote, toInputText } from "../src/shell.ts";

test("assertPackage accepts real package names and rejects anything shell-shaped", () => {
  assert.equal(assertPackage("com.android.settings"), "com.android.settings");
  assert.equal(assertPackage("dev.droidmirror.companion"), "dev.droidmirror.companion");
  for (const bad of ["", "settings", "com.x; reboot", "com.x && id", "com.x$(id)", "com x", "-p", "com..x", "../x", "com.x\nid"]) {
    assert.throws(() => assertPackage(bad), /valid package/, `should reject ${JSON.stringify(bad)}`);
  }
});

test("assertInt rounds, bounds and rejects non-numbers", () => {
  assert.equal(assertInt("x", 10.6), 11);
  assert.throws(() => assertInt("x", -1), /between/);
  assert.throws(() => assertInt("x", 1e9), /between/);
  assert.throws(() => assertInt("x", Number.NaN), /number/);
  assert.throws(() => assertInt("x", "5" as unknown as number), /number/);
});

test("shellQuote survives apostrophes and shell metacharacters", () => {
  assert.equal(shellQuote("abc"), "'abc'");
  assert.equal(shellQuote("it's"), `'it'\\''s'`);
  assert.equal(shellQuote("a;b $(id) `x`"), "'a;b $(id) `x`'");
});

test("toInputText turns spaces into %s and refuses text adb cannot type", () => {
  assert.equal(toInputText("hello world"), "hello%sworld");
  assert.equal(toInputText("100%"), "100%");
  assert.throws(() => toInputText(""), /empty/);
  assert.throws(() => toInputText("héllo"), /ASCII/);
  assert.throws(() => toInputText("emoji 😀"), /ASCII/);
  assert.throws(() => toInputText("line\nbreak"), /ASCII/);
  assert.throws(() => toInputText("50%sale"), /%s/);
  assert.throws(() => toInputText("x".repeat(501)), /500/);
});

test("keyCode maps names case-insensitively and leaves POWER out on purpose", () => {
  assert.equal(keyCode("home"), 3);
  assert.equal(keyCode("BACK"), 4);
  assert.throws(() => keyCode("POWER"), /Unknown key/);
  assert.throws(() => keyCode("3; reboot"), /Unknown key/);
  assert.ok(!("POWER" in KEYS));
});
