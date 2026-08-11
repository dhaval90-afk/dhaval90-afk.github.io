// Requires supabaseClient.js to be loaded first.
async function requireAuth() {
  const { data } = await window.sb.auth.getSession();
  if (!data.session) {
    window.location.href = 'login.html';
    return null;
  }
  return data.session;
}

async function currentUserLabel() {
  const { data } = await window.sb.auth.getUser();
  return data.user ? data.user.email : '';
}

async function signOut() {
  await window.sb.auth.signOut();
  window.location.href = 'login.html';
}
