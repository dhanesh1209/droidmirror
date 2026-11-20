import { test } from "node:test";
import assert from "node:assert/strict";
import { center, compactTree, findNodes, hasSelector, parseUiTree } from "../src/uiTree.ts";
import { SAMPLE_XML } from "./fakes.ts";

test("parseUiTree reads nodes in order with depth, flags and bounds", () => {
  const nodes = parseUiTree(SAMPLE_XML);
  assert.equal(nodes.length, 4);
  assert.equal(nodes[0]!.depth, 0);
  assert.equal(nodes[1]!.depth, 1);
  assert.equal(nodes[1]!.text, "Log in");
  assert.equal(nodes[1]!.resourceId, "com.example:id/login");
  assert.equal(nodes[1]!.clickable, true);
  assert.deepEqual(nodes[1]!.bounds, { left: 100, top: 200, right: 300, bottom: 400 });
});

test("parseUiTree decodes XML entities and survives a raw > inside an attribute", () => {
  const nodes = parseUiTree(SAMPLE_XML);
  assert.equal(nodes[2]!.text, 'a < b & "c" A');
  assert.equal(nodes[2]!.contentDesc, "x > y");
});

test("findNodes matches every field, ignores invisible nodes, and supports id suffixes", () => {
  const nodes = parseUiTree(SAMPLE_XML);
  assert.equal(findNodes(nodes, { text: "Log in" }).length, 1);
  assert.equal(findNodes(nodes, { textContains: "LOG" }).length, 1);       // case-insensitive
  assert.equal(findNodes(nodes, { resourceId: "login" }).length, 1);       // suffix after the slash
  assert.equal(findNodes(nodes, { resourceId: "com.example:id/login" }).length, 1);
  assert.equal(findNodes(nodes, { className: "Button" }).length, 1);
  assert.equal(findNodes(nodes, { clickable: true }).length, 1);
  assert.equal(findNodes(nodes, { text: "Log in", clickable: false }).length, 0);   // AND, not OR
  assert.equal(findNodes(nodes, { text: "Hidden" }).length, 0);            // zero-area node is not on screen
  assert.equal(findNodes(nodes, { contentDescContains: "X >" }).length, 1);
});

test("center and hasSelector", () => {
  assert.deepEqual(center({ left: 100, top: 200, right: 300, bottom: 400 }), { x: 200, y: 300 });
  assert.equal(hasSelector({}), false);
  assert.equal(hasSelector({ text: undefined }), false);
  assert.equal(hasSelector({ text: "x" }), true);
});

test("compactTree keeps useful nodes and truncates with a note", () => {
  const nodes = parseUiTree(SAMPLE_XML);
  const tree = compactTree(nodes);
  assert.equal(tree.total, 4);
  assert.match(tree.text, /Button text="Log in" id=com.example:id\/login .*clickable/);
  assert.doesNotMatch(tree.text, /^FrameLayout/m);                          // the empty container is skipped
  const truncated = compactTree(nodes, 1);
  assert.match(truncated.text, /more nodes not shown/);
});
