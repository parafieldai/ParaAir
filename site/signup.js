// The sign-up and billing switches. ParaAir Cloud says whether anyone may create an account (`open`, its SELF_SIGNUP)
// and whether it can charge anyone (`billing`: a payment processor is selected), and the site follows:
//   data-signup="open" / "invite": "Get started" and the free trial when sign-up is open, "Ask for an invite" while it
//     is invite-only. Until the answer comes, and whenever it can't (no script, offline, an error), the page stays as
//     written, which is invite-only.
//   data-billing="off": copy that says nobody is charged. It is written hidden and shown only when the service answers
//     that its billing is off: `billing: false`, or an answer from before the field (`open` and no `billing`), whose
//     service can't charge anyone. Anything else (no answer, a malformed one) leaves it hidden, so the page never says
//     nobody is charged while plans are being sold.
// Only elements marked data-signup or data-billing change, and only their hidden attribute.
(() => {
  const marked = document.querySelectorAll('[data-signup], [data-billing]');
  if (!marked.length || !window.fetch) return;
  fetch('https://cloud.parafield.ai/signup/status', { credentials: 'omit', mode: 'cors' })
    .then((response) => (response.ok ? response.json() : null))
    .then((status) => {
      if (!status || typeof status !== 'object' || typeof status.open !== 'boolean') return;
      const open = status.open;
      const billingOff = status.billing === false || !('billing' in status);
      for (const element of marked) {
        const signup = element.dataset.signup, billing = element.dataset.billing;
        const signupShown = signup === undefined || (open ? signup === 'open' : signup !== 'open');
        const billingShown = billing === undefined || (billing === 'off') === billingOff;
        element.hidden = !(signupShown && billingShown);
      }
    })
    .catch(() => {});
})();
