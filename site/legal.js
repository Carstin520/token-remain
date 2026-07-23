(function () {
  var button = document.getElementById("langBtn");
  var panels = document.querySelectorAll("[data-lang-panel]");
  var titles = {
    privacy: {
      en: "TokenRemain Privacy Policy",
      zh: "TokenRemain 隐私政策"
    },
    support: {
      en: "TokenRemain Support",
      zh: "TokenRemain 支持"
    }
  };
  var page = document.body.dataset.page || "privacy";

  function readStoredLanguage() {
    try { return localStorage.getItem("tr-lang"); } catch (_) { return null; }
  }

  function storeLanguage(language) {
    try { localStorage.setItem("tr-lang", language); } catch (_) {}
  }

  function apply(language) {
    var selected = language === "zh" ? "zh" : "en";
    panels.forEach(function (panel) {
      panel.hidden = panel.dataset.langPanel !== selected;
    });
    document.documentElement.lang = selected === "zh" ? "zh-CN" : "en";
    document.title = titles[page][selected];
    button.textContent = selected === "zh" ? "EN" : "中文";
    button.setAttribute("aria-label", selected === "zh" ? "Switch to English" : "切换到中文");
    storeLanguage(selected);
  }

  var queryLanguage = new URLSearchParams(location.search).get("lang");
  var initial = queryLanguage === "zh" || queryLanguage === "en"
    ? queryLanguage
    : (readStoredLanguage() || (navigator.language.toLowerCase().startsWith("zh") ? "zh" : "en"));
  apply(initial);
  button.addEventListener("click", function () {
    apply(document.documentElement.lang === "en" ? "zh" : "en");
  });
})();
