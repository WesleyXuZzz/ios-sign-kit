const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { resolve } = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

const source = readFileSync(resolve(__dirname,
  "../../Sources/IOSSignKit/Resources/LANControlWeb/app.js"), "utf8");

// Exercise the real rendering code with an isolated DOM adapter, without a server or session.
function fixture() {
  const nodes = new Map();
  const listeners = new Map();
  let document;
  function element() {
    const classes = new Set();
    return {
      hidden: true, dataset: {}, children: [], focusCount: 0, isConnected: true,
      classList: {
        add: (...names) => names.forEach(name => classes.add(name)),
        remove: (...names) => names.forEach(name => classes.delete(name)),
        toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); },
        contains: name => classes.has(name)
      },
      setAttribute() {}, removeAttribute() {}, addEventListener() {},
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
      querySelector: selector => node(selector),
      focus(options) {
        this.focusCount++;
        this.focusOptions = options;
        document.activeElement = this;
      }
    };
  }
  function node(selector) {
    if (!nodes.has(selector)) nodes.set(selector, element());
    return nodes.get(selector);
  }
  document = {
    hidden: false, documentElement: element(), body: element(), activeElement: null,
    querySelector: node, createElement: element,
    addEventListener(name, callback) { listeners.set(name, callback); }
  };
  const intervals = new Set();
  let nextInterval = 1;
  const requests = [];
  const context = vm.createContext({
    document, URLSearchParams,
    sessionStorage: { getItem: () => null },
    fetch: path => {
      requests.push(path);
      return new Promise(() => {});
    },
    window: {
      location: { search: "" }, setTimeout() {},
      setInterval() { const id = nextInterval++; intervals.add(id); return id; },
      clearInterval(id) { intervals.delete(id); }
    }
  });
  vm.runInContext(source, context);
  return {
    document, node, intervals, requests,
    run: code => vm.runInContext(code, context),
    dispatch: name => listeners.get(name)()
  };
}

test("identical progress polls retain stage nodes; changed phases still render", () => {
  const f = fixture();
  f.run('renderStages({ phases: ["构建", "安装"], phaseIndex: 0 })');
  const first = f.node("#stage-list").children[0];
  f.run('renderStages({ phases: ["构建", "安装"], phaseIndex: 0 })');
  assert.equal(f.node("#stage-list").children[0], first);
  f.run('renderStages({ phases: ["构建", "安装"], phaseIndex: 1 })');
  assert.equal(f.node("#stage-list").children[0].classList.contains("is-complete"), true);
  assert.equal(f.node("#stage-list").children[1].classList.contains("is-current"), true);
  f.run('renderStages({ phases: ["检查"], phaseIndex: 0 })');
  assert.equal(f.node("#stage-list").children.length, 1);
});

test("repeated status polls leave user focus alone and page changes do not scroll", () => {
  const f = fixture();
  f.run('showState("ready", "#ready-title")');
  f.node("#renew-button").focus();
  f.run('showState("ready", "#ready-title")');
  assert.equal(f.document.activeElement, f.node("#renew-button"));
  assert.equal(f.node("#ready-title").focusCount, 1);
  f.run('showState("progress", "#progress-title")');
  assert.equal(f.document.activeElement, f.node("#progress-title"));
  assert.equal(f.node("#progress-title").focusOptions.preventScroll, true);
});

test("a status transition cannot steal focus from the profile choice", () => {
  const f = fixture();
  f.node("#profile-choice").hidden = false;
  f.node("#profile-force").focus();
  f.run('showState("progress", "#progress-title")');
  assert.equal(f.document.activeElement, f.node("#profile-force"));
});

test("returning from login treats the next status as a new page", () => {
  const f = fixture();
  f.run('showState("ready", "#ready-title"); showLogin(); showState("ready", "#ready-title")');
  assert.equal(f.node("#ready-title").focusCount, 2);
});

test("visibility pauses and resumes motion without discarding progress nodes", () => {
  const f = fixture();
  f.run('renderStages({ phases: ["构建"], phaseIndex: 0 })');
  const first = f.node("#stage-list").children[0];
  f.document.hidden = true;
  f.dispatch("visibilitychange");
  assert.equal(f.document.documentElement.classList.contains("motion-paused"), true);
  f.document.hidden = false;
  f.dispatch("visibilitychange");
  assert.equal(f.document.documentElement.classList.contains("motion-paused"), false);
  assert.equal(f.node("#stage-list").children[0], first);
});

test("keyboard activation clears pointer motion including after mouse use", () => {
  const f = fixture();
  assert.equal(f.document.documentElement.dataset.inputMethod, "keyboard");
  f.dispatch("pointerdown");
  assert.equal(f.document.documentElement.dataset.inputMethod, "pointer");
  f.dispatch("keydown");
  assert.equal(f.document.documentElement.dataset.inputMethod, "keyboard");
});


test("profile choice focuses immediately and repeated opens preserve the original trigger", () => {
  const f = fixture();
  f.node("#renew-button").focus();
  f.run('openProfileChoice("选择策略")');
  assert.equal(f.document.activeElement, f.node("#profile-force"));
  assert.equal(f.node("#profile-force").focusOptions.preventScroll, true);
  f.run('openProfileChoice("更新说明"); closeProfileChoice()');
  assert.equal(f.document.activeElement, f.node("#renew-button"));
  assert.equal(f.node("#profile-choice").hidden, true);
});

test("login immediately focuses its field without delaying a subsequent page focus", () => {
  const f = fixture();
  f.run('showLogin()');
  assert.equal(f.document.activeElement, f.node("#password-input"));
  f.run('showState("ready", "#ready-title")');
  assert.equal(f.document.activeElement, f.node("#ready-title"));
});

test("status polling stops while hidden and catches up once when visible again", () => {
  const f = fixture();
  f.run("startPolling()");
  assert.equal(f.intervals.size, 1);
  f.document.hidden = true;
  f.dispatch("visibilitychange");
  assert.equal(f.intervals.size, 0);
  assert.equal(f.document.documentElement.classList.contains("motion-paused"), true);
  f.document.hidden = false;
  f.dispatch("visibilitychange");
  assert.equal(f.intervals.size, 1);
  assert.deepEqual(f.requests, ["/api/status"]);
  f.dispatch("visibilitychange");
  assert.equal(f.intervals.size, 1);
  assert.equal(f.requests.length, 1);
});

test("signed-out pages never resume polling on visibility changes", () => {
  const f = fixture();
  f.run("startPolling(); showLogin()");
  assert.equal(f.intervals.size, 0);
  f.document.hidden = true;
  f.dispatch("visibilitychange");
  f.document.hidden = false;
  f.dispatch("visibilitychange");
  assert.equal(f.intervals.size, 0);
  assert.equal(f.requests.length, 0);
});

test("polling started while hidden waits for the page to become visible", () => {
  const f = fixture();
  f.document.hidden = true;
  f.run("startPolling()");
  assert.equal(f.intervals.size, 0);
  f.document.hidden = false;
  f.dispatch("visibilitychange");
  assert.equal(f.intervals.size, 1);
});
