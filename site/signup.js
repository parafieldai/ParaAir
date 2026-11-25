// The sign-up switch. ParaAir Cloud says whether anyone may create an account (its SELF_SIGNUP), and the site follows:
// "Get started" and the free trial when it is open, "Ask for an invite" while it is invite-only. Until the answer
// comes, and whenever it can't (no script, offline, an error), the page stays as written, which is invite-only. Only
// elements marked data-signup change, and only their hidden attribute.
(() => {
  const marked = document.querySelectorAll('[data-signup]');
  if (!marked.length || !window.fetch) return;
  fetch('https://cloud.parafield.ai/signup/status', { credentials: 'omit', mode: 'cors' })
    .then((response) => (response.ok ? response.json() : null))
    .then((status) => {
      if (!status || status.open !== true) return;
      for (const element of marked) element.hidden = element.dataset.signup !== 'open';
    })
    .catch(() => {});
})();
