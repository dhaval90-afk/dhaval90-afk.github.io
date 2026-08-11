// Requires config.js and the supabase-js UMD bundle to be loaded first.
(function () {
  const cfg = window.WORKHALL_CONFIG || {};
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.includes('YOUR-PROJECT')) {
    console.warn('Workhall Leads: config.js still has placeholder Supabase credentials.');
  }
  window.sb = supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY);
})();
