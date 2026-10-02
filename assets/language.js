(() => {
  const storageKey = 'dunckops.language';
  const paths = { en: '/en/', 'pt-BR': '/pt-br/' };
  const suffix = window.location.search + window.location.hash;

  function saveLanguage(language) {
    try {
      window.localStorage.setItem(storageKey, language);
    } catch {
      // Navigation still works when browser storage is unavailable.
    }
  }

  document.querySelectorAll('[data-language]').forEach((link) => {
    const language = link.dataset.language;
    link.href = paths[language] + suffix;
    link.addEventListener('click', () => saveLanguage(language));
  });

  if (!document.documentElement.hasAttribute('data-language-redirect')) {
    saveLanguage(document.documentElement.lang);
    return;
  }

  let language;
  try {
    language = window.localStorage.getItem(storageKey);
  } catch {
    // Fall back to browser language when storage is blocked.
  }
  if (language !== 'en' && language !== 'pt-BR') {
    const browserLanguage = navigator.languages?.[0] || navigator.language || 'en';
    language = /^pt(?:-|$)/i.test(browserLanguage) ? 'pt-BR' : 'en';
  }
  window.location.replace(paths[language] + suffix);
})();
