(function () {
  "use strict";

  var cfg = window.STOCKWATCH_CONFIG || {};
  var SESSION_KEY = "stockwatch.session";
  var POLL_MS = 5000;

  var state = {
    session: null,
    user: null,
    products: [],
    orders: [],
    alerts: [],
    forecast: {},
    loaded: false,
    refreshError: false,
    lastUpdated: null,
    confirmDelete: null,
    busy: new Set(),
    timer: null,
  };

  // ---------- small helpers ----------

  function h(tag, props) {
    var el = document.createElement(tag);
    Object.keys(props || {}).forEach(function (k) {
      var v = props[k];
      if (k === "class") el.className = v;
      else if (k.indexOf("on") === 0 && typeof v === "function") el.addEventListener(k.slice(2), v);
      else if (v === true) el.setAttribute(k, "");
      else if (v !== false && v != null) el.setAttribute(k, v);
    });
    for (var i = 2; i < arguments.length; i++) append(el, arguments[i]);
    return el;
  }
  function append(el, kid) {
    if (kid == null || kid === false) return;
    if (Array.isArray(kid)) { kid.forEach(function (k) { append(el, k); }); return; }
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  function $(id) { return document.getElementById(id); }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  function isOwner() { return !!state.user && state.user.groups.indexOf("owner") !== -1; }

  function toast(message, kind) {
    var el = h("div", { class: "toast" + (kind === "error" ? " error" : ""), role: kind === "error" ? "alert" : "status" }, message);
    $("toasts").append(el);
    setTimeout(function () { el.remove(); }, kind === "error" ? 6000 : 3500);
  }

  function timeAgo(iso) {
    if (!iso) return "";
    var then = new Date(iso).getTime();
    if (isNaN(then)) return "";
    var s = Math.max(0, Math.round((Date.now() - then) / 1000));
    if (s < 45) return "just now";
    if (s < 3600) return Math.round(s / 60) + " min ago";
    if (s < 86400) return Math.round(s / 3600) + " h ago";
    return new Date(iso).toLocaleDateString([], { day: "numeric", month: "short" });
  }

  // ---------- session and Cognito ----------

  function loadSession() {
    try { return JSON.parse(sessionStorage.getItem(SESSION_KEY) || "null"); } catch (e) { return null; }
  }
  function saveSession(s) {
    try {
      if (s) sessionStorage.setItem(SESSION_KEY, JSON.stringify(s));
      else sessionStorage.removeItem(SESSION_KEY);
    } catch (e) { /* storage unavailable: session lasts until reload */ }
  }

  function parseJwt(token) {
    var b64 = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    var bin = atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4));
    var bytes = Uint8Array.from(bin, function (c) { return c.charCodeAt(0); });
    return JSON.parse(new TextDecoder().decode(bytes));
  }

  function userFrom(idToken) {
    var c = parseJwt(idToken);
    var groups = c["cognito:groups"] || [];
    if (typeof groups === "string") groups = groups.replace(/[\[\]]/g, "").split(/[\s,]+/).filter(Boolean);
    return { email: c.email || c["cognito:username"] || "", groups: groups, exp: c.exp };
  }

  function setSession(idToken, refreshToken) {
    var user = userFrom(idToken);
    state.user = user;
    state.session = { idToken: idToken, refreshToken: refreshToken, exp: user.exp };
    saveSession(state.session);
  }

  function idp(target, body) {
    return fetch("https://cognito-idp." + cfg.region + ".amazonaws.com/", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-amz-json-1.1",
        "X-Amz-Target": "AWSCognitoIdentityProviderService." + target,
      },
      body: JSON.stringify(body),
    }).then(function (res) {
      return res.json().then(function (data) {
        if (!res.ok) throw new Error(data.message || "Sign-in failed");
        return data;
      });
    });
  }

  function signIn(email, password) {
    return idp("InitiateAuth", {
      AuthFlow: "USER_PASSWORD_AUTH",
      ClientId: cfg.clientId,
      AuthParameters: { USERNAME: email, PASSWORD: password },
    }).then(function (r) {
      if (r.ChallengeName) {
        throw new Error("This account needs a new password before it can sign in. Ask an owner to reset it.");
      }
      setSession(r.AuthenticationResult.IdToken, r.AuthenticationResult.RefreshToken);
    });
  }

  function freshToken() {
    var s = state.session;
    if (!s) return Promise.reject(new Error("Not signed in"));
    if (s.exp - Date.now() / 1000 > 60) return Promise.resolve(s.idToken);
    return idp("InitiateAuth", {
      AuthFlow: "REFRESH_TOKEN_AUTH",
      ClientId: cfg.clientId,
      AuthParameters: { REFRESH_TOKEN: s.refreshToken },
    }).then(function (r) {
      setSession(r.AuthenticationResult.IdToken, s.refreshToken);
      return state.session.idToken;
    }).catch(function (e) {
      signOut("Your session ended. Sign in again.");
      throw e;
    });
  }

  function api(method, path, body) {
    return freshToken().then(function (token) {
      var headers = { Authorization: token };
      if (body) headers["Content-Type"] = "application/json";
      return fetch(cfg.apiUrl + path, {
        method: method,
        headers: headers,
        body: body ? JSON.stringify(body) : undefined,
      });
    }).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (res.status === 401) {
          signOut("Your session ended. Sign in again.");
          throw new Error("Session ended");
        }
        if (!res.ok) throw new Error(data.error || data.message || "Request failed (" + res.status + ")");
        return data;
      });
    });
  }

  // ---------- views ----------

  function showLogin(message) {
    $("app").hidden = true;
    $("login-view").hidden = false;
    var err = $("login-error");
    err.hidden = !message;
    err.textContent = message || "";
    $("login-btn").disabled = false;
    $("login-btn").textContent = "Sign in";
    $("password").value = "";
    $("email").focus();
  }

  function signOut(message) {
    if (state.timer) { clearInterval(state.timer); state.timer = null; }
    state.session = null;
    state.user = null;
    state.loaded = false;
    state.products = []; state.orders = []; state.alerts = [];
    saveSession(null);
    showLogin(message);
  }

  function statusOf(p) {
    if (p.stock === 0) return "out";
    if (p.stock <= p.reorder_threshold) return "low";
    return "ok";
  }
  var STOCK_LABEL = { ok: "In stock", low: "Low", out: "Out of stock" };

  var ORDER_LABEL = {
    PENDING_APPROVAL: ["Waiting for approval", "pill-pending"],
    APPROVED: ["Approved", "pill-ok"],
    SENT_TO_SUPPLIER: ["Sent to supplier", "pill-ok"],
    REJECTED: ["Rejected", ""],
    EXPIRED: ["Expired", ""],
  };

  function buildShell() {
    var owner = isOwner();
    var role = owner ? "owner" : "staff";

    var addForm = h("form", { id: "add-form", novalidate: true, hidden: true, onsubmit: onAddProduct },
      field("f-name", "Name", "text", { maxlength: 100, required: true }),
      field("f-sku", "SKU", "text", { maxlength: 50, required: true }),
      field("f-stock", "Stock", "number", { min: 0, value: 12, required: true }),
      field("f-threshold", "Reorder at", "number", { min: 0, value: 5, required: true }),
      field("f-qty", "Order quantity", "number", { min: 1, value: 50, required: true }),
      field("f-supplier", "Supplier email", "email", { maxlength: 254, required: true }),
      h("div", { class: "form-actions" },
        h("button", { class: "btn btn-primary", type: "submit", id: "f-submit" }, "Add product"),
        h("button", { class: "btn", type: "button", onclick: function () { addForm.hidden = true; $("add-toggle").hidden = false; } }, "Cancel")
      )
    );

    var addToggle = h("button", {
      id: "add-toggle", class: "btn btn-primary", type: "button", hidden: !owner,
      onclick: function () { addForm.hidden = false; addToggle.hidden = true; $("f-name").focus(); },
    }, "Add product");

    $("app").replaceChildren(
      h("header", { class: "topbar" },
        h("div", { class: "brand" }, "StockWatch"),
        h("div", { class: "who" },
          h("span", { class: "who-email" }, state.user.email),
          h("span", { class: "pill" }, role),
          h("button", { class: "btn btn-quiet", type: "button", onclick: function () { signOut(); } }, "Sign out")
        )
      ),
      h("main", { class: "page" },
        h("div", { class: "status-row" },
          h("p", { id: "status-line", class: "status-line", "aria-live": "polite" }, "Loading stock..."),
          h("span", { id: "updated", class: "updated" })
        ),
        h("div", { class: "layout" },
          h("section", { class: "panel", "aria-labelledby": "h-stock" },
            h("div", { class: "panel-head" }, h("h2", { id: "h-stock" }, "Stock"), addToggle),
            addForm,
            h("div", { id: "stock-body" })
          ),
          h("aside", { class: "rail" },
            h("section", { class: "panel", "aria-labelledby": "h-orders" },
              h("div", { class: "panel-head" }, h("h2", { id: "h-orders" }, "Purchase orders")),
              h("div", { id: "orders-body" })
            ),
            h("section", { class: "panel", "aria-labelledby": "h-alerts" },
              h("div", { class: "panel-head" }, h("h2", { id: "h-alerts" }, "Low-stock alerts")),
              h("div", { id: "alerts-body" })
            )
          )
        )
      )
    );
  }

  function field(id, label, type, attrs) {
    var input = h("input", Object.assign({ id: id, type: type }, attrs));
    return h("label", { for: id }, label, input);
  }

  function renderStatus() {
    var low = state.products.filter(function (p) { return statusOf(p) !== "ok"; }).length;
    var pending = state.orders.filter(function (o) { return o.status === "PENDING_APPROVAL"; }).length;
    var line = $("status-line");
    if (!state.loaded) return;
    var parts = [];
    if (low) parts.push(plural(low, "product is", "products are") + " low on stock.");
    if (pending) parts.push(plural(pending, "purchase order is", "purchase orders are") + " waiting for approval.");
    line.textContent = parts.length ? parts.join(" ") : "Everything is stocked. No orders are waiting.";
    line.classList.toggle("attention", parts.length > 0);
    var u = $("updated");
    u.textContent = state.refreshError
      ? "Could not refresh. Trying again."
      : state.lastUpdated ? "Updated " + state.lastUpdated.toLocaleTimeString() : "";
  }

  function stockCell(p) {
    var st = statusOf(p);
    var max = Math.max(p.reorder_threshold * 3, p.stock, 1);
    var fill = Math.min(100, (p.stock / max) * 100);
    var tick = Math.min(100, (p.reorder_threshold / max) * 100);
    return h("div", { class: "stock-cell" },
      h("span", { class: "stock-num " + st }, p.stock),
      h("div", { class: "stock-meta" },
        h("span", { class: "pill pill-" + st }, STOCK_LABEL[st]),
        h("div", { class: "meter", role: "img", "aria-label": p.stock + " in stock, reorder at " + p.reorder_threshold },
          h("div", { class: "meter-fill " + st, style: "width:" + fill + "%" }),
          h("div", { class: "meter-tick", style: "left:" + tick + "%" })
        )
      )
    );
  }

  function forecastCell(p) {
    var f = state.forecast[p.product_id];
    if (!f) return h("span", { class: "p-sku" }, "No data");
    if (f.days_left === null || f.days_left === undefined) {
      return h("span", { class: "p-sku" }, "No sales in 7 days");
    }
    var soon = f.days_left <= 7;
    return h("div", null,
      h("span", { class: "pill " + (soon ? "pill-low" : "pill-ok") }, "Runs out in " + f.days_left + " days"),
      h("div", { class: "p-sku" }, f.avg_daily + " a day, order " + f.suggested_qty)
    );
  }

  function productActions(p) {
    var id = p.product_id;
    var busy = state.busy.has("adj:" + id) || state.busy.has("del:" + id);
    var btns = [
      h("button", { class: "btn", type: "button", disabled: busy || p.stock < 1, "aria-label": "Sell 1 of " + p.name, onclick: function () { adjust(p, -1); } }, "Sell 1"),
      h("button", { class: "btn", type: "button", disabled: busy || p.stock < 5, "aria-label": "Sell 5 of " + p.name, onclick: function () { adjust(p, -5); } }, "Sell 5"),
      h("button", { class: "btn", type: "button", disabled: busy, "aria-label": "Restock 10 of " + p.name, onclick: function () { adjust(p, 10); } }, "Restock 10"),
    ];
    if (isOwner()) {
      if (state.confirmDelete === id) {
        btns.push(
          h("button", { class: "btn btn-danger", type: "button", disabled: busy, onclick: function () { removeProduct(p); } }, "Delete " + p.name + "?"),
          h("button", { class: "btn btn-quiet", type: "button", onclick: function () { state.confirmDelete = null; renderProducts(); } }, "Keep")
        );
      } else {
        btns.push(h("button", { class: "btn btn-quiet", type: "button", disabled: busy, "aria-label": "Delete " + p.name, onclick: function () { state.confirmDelete = id; renderProducts(); } }, "Delete"));
      }
    }
    return h("div", { class: "actions" }, btns);
  }

  function renderProducts() {
    var body = $("stock-body");
    if (!body) return;
    if (!state.loaded) { body.replaceChildren(); return; }
    if (!state.products.length) {
      body.replaceChildren(h("p", { class: "empty" }, isOwner()
        ? "No products yet. Add your first product to start tracking stock."
        : "No products yet. Ask an owner to add one."));
      return;
    }
    var rows = state.products.map(function (p) {
      return h("tr", null,
        h("td", null, h("div", { class: "p-name" }, p.name), h("div", { class: "p-sku" }, p.sku)),
        h("td", null, stockCell(p)),
        h("td", { class: "num" }, p.reorder_threshold),
        h("td", { class: "num col-qty" }, p.reorder_qty),
        h("td", { class: "col-forecast" }, forecastCell(p)),
        h("td", { class: "col-supplier" }, p.supplier_email),
        h("td", null, productActions(p))
      );
    });
    body.replaceChildren(
      h("div", { class: "table-wrap" },
        h("table", null,
          h("caption", { class: "sr-only" }, "Stock list"),
          h("thead", null, h("tr", null,
            h("th", { scope: "col" }, "Product"),
            h("th", { scope: "col" }, "In stock"),
            h("th", { scope: "col" }, "Reorder at"),
            h("th", { scope: "col", class: "col-qty" }, "Order qty"),
            h("th", { scope: "col", class: "col-forecast" }, "Forecast"),
            h("th", { scope: "col", class: "col-supplier" }, "Supplier"),
            h("th", { scope: "col" }, h("span", { class: "sr-only" }, "Actions"))
          )),
          h("tbody", null, rows)
        )
      )
    );
  }

  function renderOrders() {
    var body = $("orders-body");
    if (!body) return;
    if (!state.loaded) { body.replaceChildren(); return; }
    if (!state.orders.length) {
      body.replaceChildren(h("p", { class: "empty" }, "No purchase orders yet. One is created automatically when a product runs low."));
      return;
    }
    var sorted = state.orders.slice().sort(function (a, b) {
      var pa = a.status === "PENDING_APPROVAL" ? 0 : 1;
      var pb = b.status === "PENDING_APPROVAL" ? 0 : 1;
      if (pa !== pb) return pa - pb;
      return String(b.created_at).localeCompare(String(a.created_at));
    }).slice(0, 8);

    body.replaceChildren(h("ul", { class: "list" }, sorted.map(function (o) {
      var label = ORDER_LABEL[o.status] || [o.status, ""];
      var pending = o.status === "PENDING_APPROVAL";
      var busy = state.busy.has("ord:" + o.po_id);
      return h("li", null,
        h("div", { class: "item-top" },
          h("span", { class: "item-title" }, o.quantity + " × " + o.product_name),
          h("span", { class: "pill " + label[1] }, label[0])
        ),
        h("div", { class: "item-sub" }, "Supplier " + o.supplier_email + " • " + timeAgo(o.created_at)),
        pending && isOwner()
          ? h("div", { class: "actions" },
              h("button", { class: "btn btn-primary", type: "button", disabled: busy, "aria-label": "Approve order for " + o.product_name, onclick: function () { decide(o, true); } }, "Approve"),
              h("button", { class: "btn", type: "button", disabled: busy, "aria-label": "Reject order for " + o.product_name, onclick: function () { decide(o, false); } }, "Reject"))
          : pending
            ? h("div", { class: "item-sub" }, "An owner needs to approve this order.")
            : null
      );
    })));
  }

  function renderAlerts() {
    var body = $("alerts-body");
    if (!body) return;
    if (!state.loaded) { body.replaceChildren(); return; }
    if (!state.alerts.length) {
      body.replaceChildren(h("p", { class: "empty" }, "No alerts yet. One shows up here when a product drops to its reorder level."));
      return;
    }
    body.replaceChildren(h("ul", { class: "list" }, state.alerts.slice(0, 10).map(function (a) {
      return h("li", null,
        h("div", { class: "item-top" },
          h("span", { class: "item-title" }, a.name),
          h("span", { class: "item-sub" }, timeAgo(a.detected_at))
        ),
        h("div", { class: "item-sub" }, a.stock + " left, reorder at " + a.reorder_threshold + (a.status === "NOTIFIED" ? ". Email sent." : "."))
      );
    })));
  }

  function renderAll() {
    renderStatus();
    renderProducts();
    renderOrders();
    renderAlerts();
  }

  // ---------- data and actions ----------

  function refresh() {
    return Promise.all([
      api("GET", "/products?limit=100"),
      api("GET", "/orders?limit=50"),
      api("GET", "/alerts?limit=20"),
      // Forecast is optional: it only exists once the analytics module is deployed.
      api("GET", "/forecast").catch(function () { return { items: [] }; }),
    ]).then(function (r) {
      state.forecast = {};
      (r[3].items || []).forEach(function (f) { state.forecast[f.product_id] = f; });
      state.products = r[0].items || [];
      state.orders = r[1].items || [];
      state.alerts = r[2].items || [];
      state.loaded = true;
      state.refreshError = false;
      state.lastUpdated = new Date();
      renderAll();
    }).catch(function () {
      if (!state.session) return;
      state.refreshError = true;
      renderStatus();
    });
  }

  function withBusy(key, fn) {
    if (state.busy.has(key)) return Promise.resolve();
    state.busy.add(key);
    renderAll();
    return fn().finally(function () {
      state.busy.delete(key);
      renderAll();
    });
  }

  function adjust(p, delta) {
    return withBusy("adj:" + p.product_id, function () {
      return api("POST", "/products/" + encodeURIComponent(p.product_id) + "/stock", { delta: delta })
        .then(function (r) { toast(r.name + ": " + r.stock + " in stock"); return refresh(); })
        .catch(function (e) { toast(e.message, "error"); });
    });
  }

  function removeProduct(p) {
    return withBusy("del:" + p.product_id, function () {
      return api("DELETE", "/products/" + encodeURIComponent(p.product_id))
        .then(function () { state.confirmDelete = null; toast("Deleted " + p.name); return refresh(); })
        .catch(function (e) { toast(e.message, "error"); });
    });
  }

  function decide(o, approve) {
    return withBusy("ord:" + o.po_id, function () {
      return api("POST", "/orders/" + encodeURIComponent(o.po_id) + (approve ? "/approve" : "/reject"))
        .then(function () { toast(approve ? "Order approved" : "Order rejected"); return refresh(); })
        .catch(function (e) { toast(e.message, "error"); });
    });
  }

  function onAddProduct(ev) {
    ev.preventDefault();
    var btn = $("f-submit");
    var body = {
      name: $("f-name").value.trim(),
      sku: $("f-sku").value.trim(),
      stock: parseInt($("f-stock").value, 10),
      reorder_threshold: parseInt($("f-threshold").value, 10),
      reorder_qty: parseInt($("f-qty").value, 10),
      supplier_email: $("f-supplier").value.trim(),
    };
    if (!body.name || !body.sku || !body.supplier_email ||
        isNaN(body.stock) || isNaN(body.reorder_threshold) || isNaN(body.reorder_qty)) {
      toast("Fill in every field to add a product.", "error");
      return;
    }
    btn.disabled = true;
    api("POST", "/products", body)
      .then(function () {
        toast("Added " + body.name);
        ev.target.reset();
        $("add-form").hidden = true;
        $("add-toggle").hidden = false;
        return refresh();
      })
      .catch(function (e) { toast(e.message, "error"); })
      .finally(function () { btn.disabled = false; });
  }

  // ---------- start up ----------

  function startApp() {
    $("login-view").hidden = true;
    $("app").hidden = false;
    buildShell();
    renderAll();
    refresh();
    if (state.timer) clearInterval(state.timer);
    state.timer = setInterval(function () {
      if (!document.hidden && state.session) refresh();
    }, POLL_MS);
  }

  document.addEventListener("visibilitychange", function () {
    if (!document.hidden && state.session) refresh();
  });

  $("login-form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var email = $("email").value.trim();
    var password = $("password").value;
    var err = $("login-error");
    err.hidden = true;
    if (!email || !password) {
      err.textContent = "Enter your email and password.";
      err.hidden = false;
      return;
    }
    var btn = $("login-btn");
    btn.disabled = true;
    btn.textContent = "Signing in...";
    signIn(email, password)
      .then(startApp)
      .catch(function (e) {
        err.textContent = e.message;
        err.hidden = false;
        btn.disabled = false;
        btn.textContent = "Sign in";
      });
  });

  (function boot() {
    if (!cfg.apiUrl || !cfg.clientId || !cfg.region) {
      showLogin("This site is missing its configuration (config.js).");
      return;
    }
    var saved = loadSession();
    if (saved && saved.idToken && saved.refreshToken) {
      try {
        state.session = saved;
        state.user = userFrom(saved.idToken);
        startApp();
        return;
      } catch (e) {
        state.session = null;
        state.user = null;
      }
    }
    showLogin();
  })();
})();
