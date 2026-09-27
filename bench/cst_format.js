// cst_format.js — the V8 reference for cst_format.clj: the same payload, parse
// and format, written the way the upstream standard-clojure-style-js writes
// them — plain objects mutated in place and output built with `+=`, which V8
// turns into cons-strings. The Clojure side keeps the Clojure idiom (a
// persistent map per token, an atom per node, a copying `str`), so the gap
// between this and JVM Clojure is the idiom's, and jolt vs JVM is jolt's.
//
// bench/run.sh runs it beside the cst-format row when `node` is on PATH and
// prints the `verify:` line so both sides can be checked for the same parse.
//
//   node bench/cst_format.js 80

"use strict";

const unitForms = [
  "(ns example.core.unit%d\n  (:require [clojure.string :as str]\n            [clojure.set :as set]))",
  "(def ^:private lookup-%d\n  {:alpha 1, :beta 2, :gamma 3, :delta \"four\", :epsilon [5 6 7]})",
  "(defn transform-%d\n  \"Doc string for the transform.\"\n  [{:keys [a b c] :or {c 3}} xs]\n  (->> xs\n       (map (fn [x] (+ x a b c)))\n       (filter odd?)\n       (reduce + 0)))",
  ";; a comment line about entry %d\n(defrecord Point%d [x y]\n  Object\n  (toString [_] (str \"<\" x \",\" y \">\")))",
  "(defn scan-%d [^String s]\n  (loop [i 0 acc 0]\n    (if (< i (.length s))\n      (recur (inc i) (+ acc (int (.charAt s i))))\n      acc)))",
  "(let [m {:k %d :v \"string with (parens) and [brackets]\"}]\n  (case (:k m)\n    0 :zero\n    1 :one\n    :many))",
];

function buildPayload(units) {
  const forms = [];
  for (let i = 0; i < units; i++) {
    for (const f of unitForms) forms.push(f.split("%d").join(String(i)));
  }
  return forms.join("\n\n");
}

let idCounter = 0;

function makeNode(children, endIdx, name, startIdx, text) {
  return {
    id: ++idCounter,
    startIdx,
    endIdx,
    name,
    text,
    children,
    _origColIdx: -1,
    _printedColIdx: -1,
    _printedLineIdx: -1,
    _wasSlurpedUp: false,
  };
}

function appendChildren(acc, node) {
  if (typeof node.name === "string" && node.name !== "") acc.push(node);
  else if (Array.isArray(node.children)) for (const c of node.children) appendChildren(acc, c);
  return acc;
}

const registry = {};
const parserOf = (p) => (typeof p === "string" ? registry[p] : p);

function pChar(name, c) {
  return {
    name,
    parse: (txt, pos) => (pos < txt.length && txt[pos] === c ? makeNode(null, pos + 1, name, pos, c) : null),
  };
}

function pNotChar(name, c) {
  return {
    name,
    parse: (txt, pos) =>
      pos < txt.length && txt[pos] !== c ? makeNode(null, pos + 1, name, pos, txt.substring(pos, pos + 1)) : null,
  };
}

const chunkLen = 2048;

function pRegex(name, re) {
  return {
    name,
    parse: (txt, pos) => {
      if (pos >= txt.length) return null;
      const sub = txt.length - pos <= chunkLen ? txt.substring(pos) : txt.substring(pos, pos + chunkLen);
      const m = re.exec(sub);
      return m ? makeNode(null, pos + m[0].length, name, pos, m[0]) : null;
    },
  };
}

function pSeq(name, refs) {
  return {
    name,
    parse: (txt, pos) => {
      const children = [];
      let endIdx = pos;
      for (const r of refs) {
        const node = parserOf(r).parse(txt, endIdx);
        if (!node) return null;
        appendChildren(children, node);
        endIdx = node.endIdx;
      }
      return makeNode(children, endIdx, name, pos, null);
    },
  };
}

function pChoice(refs) {
  return {
    parse: (txt, pos) => {
      for (const r of refs) {
        const node = parserOf(r).parse(txt, pos);
        if (node) return node;
      }
      return null;
    },
  };
}

function pRepeat(name, ref) {
  return {
    parse: (txt, pos) => {
      const p = parserOf(ref);
      const children = [];
      let endIdx = pos;
      let node;
      while ((node = p.parse(txt, endIdx))) {
        endIdx = node.endIdx;
        appendChildren(children, node);
      }
      return makeNode(children, endIdx, typeof name === "string" && endIdx > pos ? name : null, pos, null);
    },
  };
}

function pOptional(ref) {
  return {
    parse: (txt, pos) => {
      const node = parserOf(ref).parse(txt, pos);
      return node && typeof node.text === "string" && node.text !== "" ? node : makeNode(null, pos, null, pos, null);
    },
  };
}

const wsChars = " ,\n\r\t\f";

function initParsers() {
  const esc = wsChars.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t").replace("\f", "\\f");
  registry.token = pRegex("token", new RegExp("^[^()\\[\\]{}\";" + esc + "][^()\\[\\]{}\";" + esc + "]*"));
  registry.ws = pRegex("whitespace", new RegExp("^[" + esc + "]+"));
  registry.comment = pRegex("comment", /^;[^\n]*/);
  registry.string = pSeq("string", [pChar(".open", '"'), pOptional(pRegex(".body", /^([^"\\]+|\\.)+/)), pOptional(pChar(".close", '"'))]);
  for (const [k, o, c] of [["parens", "(", ")"], ["brackets", "[", "]"], ["braces", "{", "}"]]) {
    registry[k] = pSeq(k, [pChar(".open", o), pRepeat(".body", pChoice(["_gap", "_form", pNotChar("error", c)])), pOptional(pChar(".close", c))]);
  }
  registry._gap = {
    parse: (txt, pos) => {
      if (pos >= txt.length) return null;
      const ch = txt[pos];
      if (wsChars.includes(ch)) return registry.ws.parse(txt, pos);
      if (ch === ";") return registry.comment.parse(txt, pos);
      return null;
    },
  };
  registry._form = {
    parse: (txt, pos) => {
      if (pos >= txt.length) return null;
      switch (txt[pos]) {
        case "(": return registry.parens.parse(txt, pos);
        case "[": return registry.brackets.parse(txt, pos);
        case "{": return registry.braces.parse(txt, pos);
        case '"': return registry.string.parse(txt, pos);
        default: return registry.token.parse(txt, pos);
      }
    },
  };
  registry.source = pRepeat("source", pChoice(["_gap", "_form"]));
}

const parse = (txt) => registry.source.parse(txt, 0);

function flattenTree(node, acc = []) {
  acc.push(node);
  if (Array.isArray(node.children)) for (const c of node.children) flattenTree(c, acc);
  return acc;
}

const isNewlineNode = (n) => n.name === "whitespace" && typeof n.text === "string" && n.text.includes("\n");
const isOpener = (n) => n.name === ".open" && typeof n.text === "string";
const isCloser = (n) => n.name === ".close" && typeof n.text === "string";

function countNewlines(s) {
  let n = 0;
  for (let i = 0; i < s.length; i++) if (s[i] === "\n") n++;
  return n;
}

function charsAfterLastNewline(s) {
  const i = s.lastIndexOf("\n");
  return i < 0 ? s.length : s.length - (i + 1);
}

function formatNodes(nodes) {
  let outTxt = "", lineTxt = "", lineIdx = 0, colIdx = 0, depth = 0, printed = 0;
  const parenStack = [];
  for (const node of nodes) {
    const top = parenStack[parenStack.length - 1];
    if (isOpener(node)) {
      depth++;
      if (top) top._openingLineNodes.push(node);
      node._colIdx = colIdx;
      node._parenOpenerLineIdx = lineIdx;
      node._openingLineNodes = [];
      node._rule3Active = false;
      node._rule3NumSpaces = 0;
      node._rule3SearchComplete = false;
      parenStack.push(node);
    } else if (isCloser(node)) {
      depth--;
      parenStack.pop();
    } else if (top && typeof node.text === "string" && lineIdx === top._parenOpenerLineIdx) {
      node._colIdx = colIdx;
      node._lineIdx = lineIdx;
      top._openingLineNodes.push(node);
    }
    const txt = node.text;
    if (typeof txt === "string" && txt !== "") {
      if (isNewlineNode(node)) {
        outTxt += lineTxt + txt;
        lineTxt = "";
        lineIdx += countNewlines(txt);
        colIdx = charsAfterLastNewline(txt);
      } else {
        node._printedColIdx = lineTxt.length;
        node._printedLineIdx = lineIdx;
        lineTxt += txt;
        colIdx += txt.length;
        printed++;
      }
    }
  }
  if (lineTxt !== "") outTxt += lineTxt;
  return { out: outTxt.trim(), printed, nodes: nodes.length };
}

const run = (payload) => formatNodes(flattenTree(parse(payload)));

function verify(payload) {
  const tree = parse(payload);
  const nodes = flattenTree(tree);
  const r = formatNodes(nodes);
  if (tree.endIdx !== payload.length) console.log("PARSE SHORT:", tree.endIdx, "of", payload.length);
  if (payload.trim() !== r.out) console.log("FORMAT MISMATCH: out", r.out.length, "in", payload.trim().length);
  return `[${nodes.length} ${r.printed}]`;
}

const round1 = (x) => Math.round(x * 10) / 10;
const now = () => Number(process.hrtime.bigint()) / 1e6;

function main() {
  const units = process.argv[2] ? parseInt(process.argv[2], 10) : 6;
  const payload = buildPayload(units);
  initParsers();
  console.log("payload chars:", payload.length, "verify:", verify(payload));
  for (let i = 0; i < 2; i++) run(payload); // warmup
  const runs = 3;
  let t0 = now();
  const tree = parse(payload);
  const tp = now() - t0;
  const nodes = flattenTree(tree);
  t0 = now();
  formatNodes(nodes);
  const tf = now() - t0;
  const ts = [];
  for (let i = 0; i < runs; i++) {
    t0 = now();
    const r = run(payload);
    ts.push(now() - t0);
    if (r.printed === 0) console.log("unexpected empty format");
  }
  const mean = ts.reduce((a, b) => a + b, 0) / runs;
  console.log("phases: parse", round1(tp), "ms  format", round1(tf), "ms");
  console.log("runs:", `[${ts.map(round1).join(" ")}]`);
  console.log("mean:", round1(mean), "ms");
}

main();
