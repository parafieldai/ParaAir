// The sign-up and billing switches. ParaAir Cloud says whether anyone may create an account (`open`, its SELF_SIGNUP)
// and whether it can charge anyone (`billing`: a payment processor is selected), and the site follows:
//   data-signup="open" / "invite": "Get started" and the free trial when sign-up is open, "Ask for an invite" while it
//     is invite-only. Until the answer comes, and whenever it can't (no script, offline, an error), the page stays as
//     written, which is invite-only.
//   data-billing="off": copy that says nobody is charged. It is written hidden and shown only when the service answers
//     and its billing is off, so the page never says nobody is charged while plans are being sold. A service from before
//     the field doesn't send `billing`, and can't charge anyone.
// Only elements marked data-signup or data-billing change, and only their hidden attribute.
(() => {
  const marked = document.querySelectorAll('[data-signup], [data-billing]');
  if (!marked.length || !window.fetch) return;
  fetch('https://cloud.parafield.ai/signup/status', { credentials: 'omit', mode: 'cors' })
    .then((response) => (response.ok ? response.json() : null))
    .then((status) => {
      if (!status) return;
      const open = status.open === true;
      const billingOff = status.billing !== true;
      for (const element of marked) {
        const signup = element.dataset.signup, billing = element.dataset.billing;
        const signupShown = signup === undefined || (open ? signup === 'open' : signup !== 'open');
        const billingShown = billing === undefined || (billing === 'off') === billingOff;
        element.hidden = !(signupShown && billingShown);
      }
    })
    .catch(() => {});
})();
