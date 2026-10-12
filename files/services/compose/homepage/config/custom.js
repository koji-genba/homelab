(() => {
  "use strict";

  const selector = '.service[id^="copy-storage-"], .service[id^="copy-ssh-"]';
  const groups = new Set(["ストレージ (SMB/NFS)", "SSH 先"]);
  const timers = new WeakMap();
  let searchState = "";

  // v2.5.0's built-in Quick Launch excludes services without href.
  // Supplement its dialog with local copy results, preserving href-less cards.
  function enhanceSearch() {
    const dialog = document.querySelector('[role="dialog"][aria-hidden="false"] dialog');
    const input = dialog?.querySelector('input[type="text"]');
    const query = input?.value.trim().toLocaleLowerCase() || "";
    if (!dialog || !query) {
      document.querySelector(".copy-search-results")?.remove();
      searchState = "";
      return;
    }
    const matches = Array.from(document.querySelectorAll(selector)).filter((service) => {
      if (!eligible(service)) return false;
      const description = service.querySelector(".service-description")?.textContent || "";
      return `${service.dataset.name}\n${description}`.toLocaleLowerCase().includes(query);
    }).sort((a, b) => Number(b.dataset.name.toLocaleLowerCase().includes(query))
      - Number(a.dataset.name.toLocaleLowerCase().includes(query)));
    const state = JSON.stringify([query, matches.map((service) => [
      service.id, service.dataset.name, service.querySelector(".service-description").textContent,
    ])]);
    let results = dialog.querySelector(".copy-search-results");
    if (state === searchState && (results || !matches.length)) return;
    searchState = state;
    if (!matches.length) {
      results?.remove();
      return;
    }
    if (!results) {
      results = document.createElement("section");
      results.className = "copy-search-results";
      results.setAttribute("aria-label", "接続先をコピー");
      dialog.append(results);
    }
    const label = document.createElement("p");
    label.textContent = "接続先をコピー（クリック / Tabで選択）";
    const list = document.createElement("ul");
    matches.forEach((service) => {
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = "copy-search-button";
      button.dataset.serviceId = service.id;
      const name = document.createElement("strong");
      name.textContent = service.dataset.name;
      const description = document.createElement("span");
      description.className = "copy-search-description";
      description.textContent = service.querySelector(".service-description").textContent;
      button.append(name, description);
      item.append(button);
      list.append(item);
    });
    results.replaceChildren(label, list);
  }

  function eligible(service) {
    const group = service?.closest(".services-group");
    return groups.has(group?.querySelector(".service-group-name")?.textContent.trim())
      && !service.querySelector("a[href]");
  }

  function enhance() {
    document.querySelectorAll(selector).forEach((service) => {
      if (!eligible(service)) return;
      const card = service.querySelector(".service-card");
      if (!card) return;
      card.classList.add("copy-ready");
      card.tabIndex = 0;
      card.setAttribute("role", "button");
      card.setAttribute("aria-label", `${service.dataset.name}：接続先の1行目をコピー`);
      card.title = "クリックで1行目をコピー（文字の選択も可能）";
      if (!card.querySelector(".copy-feedback")) {
        const feedback = document.createElement("span");
        feedback.className = "copy-feedback";
        feedback.setAttribute("role", "status");
        feedback.setAttribute("aria-live", "polite");
        card.append(feedback);
      }
    });
    enhanceSearch();
  }

  function fallbackCopy(text) {
    const selection = window.getSelection();
    const ranges = selection
      ? Array.from({ length: selection.rangeCount }, (_, i) => selection.getRangeAt(i).cloneRange())
      : [];
    const focus = document.activeElement;
    const input = document.createElement("textarea");
    input.value = text;
    input.readOnly = true;
    input.tabIndex = -1;
    input.style.cssText = "position:fixed;top:0;left:-9999px;opacity:0";
    document.body.append(input);
    try {
      input.select();
      if (!document.execCommand("copy")) throw new Error("Copy failed");
    } finally {
      input.remove();
      focus?.focus({ preventScroll: true });
      if (selection) {
        selection.removeAllRanges();
        ranges.forEach((range) => selection.addRange(range));
      }
    }
  }

  async function copy(service) {
    if (!eligible(service)) return;
    const card = service.querySelector(".service-card");
    const text = service.querySelector(".service-description")?.textContent.split(/\r?\n/, 1)[0];
    if (!card || !text) return;
    let success = false;
    try {
      try {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
        await navigator.clipboard.writeText(text);
      } catch {
        fallbackCopy(text);
      }
      success = true;
    } catch {
      // Keep the original text selectable when both clipboard APIs fail.
    }
    const feedback = card.querySelector(".copy-feedback");
    clearTimeout(timers.get(card));
    card.classList.toggle("copy-success", success);
    card.classList.toggle("copy-error", !success);
    if (feedback) feedback.textContent = success ? "コピーしました" : "文字を選択してコピーしてください";
    timers.set(card, setTimeout(() => {
      card.classList.remove("copy-success", "copy-error");
      if (feedback) feedback.textContent = "";
      timers.delete(card);
    }, 2400));
    return success;
  }

  // Delegation survives card replacement by React/SWR.
  document.addEventListener("click", (event) => {
    if (!(event.target instanceof Element) || event.button !== 0 || event.detail > 1) return;
    if (window.getSelection()?.toString()) return;
    const result = event.target.closest(".copy-search-button");
    if (result) {
      const service = document.getElementById(result.dataset.serviceId);
      if (service?.matches(selector)) {
        void copy(service).then((success) => {
          const feedback = document.createElement("span");
          feedback.className = "copy-search-feedback";
          feedback.setAttribute("role", "status");
          feedback.textContent = success ? "コピーしました" : "文字を選択してコピーしてください";
          result.querySelector(".copy-search-feedback")?.remove();
          result.append(feedback);
          setTimeout(() => feedback.remove(), 2400);
        });
      }
      return;
    }
    const service = event.target.closest(selector);
    if (service && event.target.closest(".service-card")) void copy(service);
  });

  document.addEventListener("input", (event) => {
    if (event.target instanceof Element && event.target.closest('[role="dialog"] dialog')) {
      enhanceSearch();
    }
  });

  document.addEventListener("keydown", (event) => {
    if (!(event.target instanceof Element) || !event.target.matches(".copy-ready")) return;
    if (event.key !== "Enter" && event.key !== " ") return;
    const service = event.target.closest(selector);
    if (!service) return;
    event.preventDefault();
    void copy(service);
  });

  function start() {
    enhance();
    let scheduled = false;
    new MutationObserver(() => {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(() => {
        scheduled = false;
        enhance();
      });
    }).observe(document.body, {
      childList: true, subtree: true, characterData: true,
      attributes: true, attributeFilter: ["aria-hidden"],
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
