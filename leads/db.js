// Shared data-access helpers. Requires supabaseClient.js to be loaded first.
const STAGES = ['New', 'Attempting Contact', 'Connected', 'Qualified', 'Meeting Booked', 'Opportunity', 'Won', 'Lost', 'Nurture / Recycle'];
const ACTIVE_STAGES = ['New', 'Attempting Contact', 'Connected', 'Qualified', 'Meeting Booked', 'Opportunity'];
const PRIORITIES = ['P1', 'P2', 'P3'];
const SOURCES = ['Website forms', 'Meta/Facebook ads', 'Google ads', 'LinkedIn campaigns', 'WhatsApp/chat', 'Events or webinars', 'Manual spreadsheet uploads', 'Referrals/partners', 'Apollo.io', 'Instantly'];
const ACTIVITY_TYPES = ['Email sent', 'Email reply received', 'Call attempted', 'Call connected', 'LinkedIn message sent', 'LinkedIn reply received', 'WhatsApp message sent', 'WhatsApp message reply', 'Meeting booked', 'Meeting completed', 'Follow-up scheduled', 'Note added', 'Status updated'];

async function fetchCompanies(filters = {}) {
  let q = window.sb.from('companies').select('*').order('created_at', { ascending: false });
  if (filters.stage) q = q.eq('stage', filters.stage);
  if (filters.source) q = q.eq('source', filters.source);
  if (filters.owner) q = q.eq('owner', filters.owner);
  if (filters.priority) q = q.eq('priority', filters.priority);
  if (filters.verification_status) q = q.eq('verification_status', filters.verification_status);
  if (filters.search) q = q.or(`company_name.ilike.%${filters.search}%,domain.ilike.%${filters.search}%`);
  const { data, error } = await q;
  if (error) throw error;
  return data;
}

async function fetchCompany(id) {
  const { data, error } = await window.sb.from('companies').select('*').eq('id', id).single();
  if (error) throw error;
  return data;
}

async function createCompany(fields) {
  const { data, error } = await window.sb.from('companies').insert(fields).select().single();
  if (error) throw error;
  return data;
}

async function updateCompany(id, fields) {
  const { data, error } = await window.sb.from('companies').update(fields).eq('id', id).select().single();
  if (error) throw error;
  return data;
}

async function fetchAllActivities() {
  const { data, error } = await window.sb.from('activities').select('*');
  if (error) throw error;
  return data;
}

async function fetchContacts(companyId) {
  const { data, error } = await window.sb.from('contacts').select('*').eq('company_id', companyId).order('primary_contact_flag', { ascending: false });
  if (error) throw error;
  return data;
}

async function fetchAllContacts() {
  const { data, error } = await window.sb.from('contacts').select('*');
  if (error) throw error;
  return data;
}

async function createContact(fields) {
  const { data, error } = await window.sb.from('contacts').insert(fields).select().single();
  if (error) throw error;
  return data;
}

async function updateContact(id, fields) {
  const { data, error } = await window.sb.from('contacts').update(fields).eq('id', id).select().single();
  if (error) throw error;
  return data;
}

async function fetchActivities(companyId) {
  const { data, error } = await window.sb.from('activities').select('*, contacts(contact_name)').eq('company_id', companyId).order('activity_datetime', { ascending: false });
  if (error) throw error;
  return data;
}

async function logActivity(fields) {
  const { data, error } = await window.sb.from('activities').insert(fields).select().single();
  if (error) throw error;
  return data;
}

async function fetchTasks(filters = {}) {
  let q = window.sb.from('tasks').select('*, companies(company_name), contacts(contact_name)').order('due_date', { ascending: true });
  if (filters.status) q = q.eq('status', filters.status);
  if (filters.owner) q = q.eq('owner', filters.owner);
  if (filters.companyId) q = q.eq('company_id', filters.companyId);
  const { data, error } = await q;
  if (error) throw error;
  return data;
}

async function createTask(fields) {
  const { data, error } = await window.sb.from('tasks').insert(fields).select().single();
  if (error) throw error;
  return data;
}

async function completeTask(id) {
  const { data, error } = await window.sb.from('tasks').update({ status: 'Completed', completed_at: new Date().toISOString() }).eq('id', id).select().single();
  if (error) throw error;
  return data;
}

async function overridePriority(companyId, newPriority, reason, changedBy) {
  const { error } = await window.sb.rpc('override_priority', {
    p_company_id: companyId, p_new_priority: newPriority, p_reason: reason, p_changed_by: changedBy,
  });
  if (error) throw error;
}

async function overrideStage(companyId, newStage, reason, changedBy) {
  const { error } = await window.sb.rpc('override_stage', {
    p_company_id: companyId, p_new_stage: newStage, p_reason: reason, p_changed_by: changedBy,
  });
  if (error) throw error;
}

async function qualifyCompany(companyId, decision, reason, routingPath, changedBy) {
  const { error } = await window.sb.rpc('qualify_company', {
    p_company_id: companyId, p_decision: decision, p_reason: reason, p_routing_path: routingPath, p_changed_by: changedBy,
  });
  if (error) throw error;
}

async function createImportBatch(filename, importedBy, rowCount) {
  const { data, error } = await window.sb.from('import_batches').insert({ filename, imported_by: importedBy, row_count: rowCount }).select().single();
  if (error) throw error;
  return data;
}

async function createImportRows(rows) {
  const { error } = await window.sb.from('import_rows').insert(rows);
  if (error) throw error;
}

async function fetchImportRows(status) {
  let q = window.sb.from('import_rows').select('*, import_batches(filename, imported_at)').order('created_at', { ascending: false });
  if (status) q = q.eq('status', status);
  const { data, error } = await q;
  if (error) throw error;
  return data;
}

async function approveImportRow(row, reviewedBy) {
  const raw = row.raw_data;
  let companyId = row.matched_company_id;
  if (companyId) {
    const existing = await fetchCompany(companyId);
    const patch = {};
    ['industry', 'company_size', 'geography', 'revenue', 'source'].forEach((f) => {
      if (!existing[f] && raw[f]) patch[f] = raw[f];
    });
    if (Object.keys(patch).length) await updateCompany(companyId, patch);
  } else {
    const created = await createCompany({
      company_name: raw.company_name,
      domain: raw.domain || null,
      industry: raw.industry || null,
      company_size: raw.company_size || null,
      geography: raw.geography || null,
      revenue: raw.revenue || null,
      source: raw.source || 'Manual spreadsheet uploads',
      source_category: raw.source_category || 'Outbound',
      verification_status: 'Pending',
    });
    companyId = created.id;
  }
  if (raw.contact_name) {
    await createContact({
      company_id: companyId,
      contact_name: raw.contact_name,
      title: raw.title || null,
      email: raw.email || null,
      phone_whatsapp: raw.phone_whatsapp || null,
      linkedin_url: raw.linkedin_url || null,
      verification_status: 'Pending',
    });
  }
  const { error } = await window.sb.from('import_rows').update({
    status: 'Approved', reviewed_by: reviewedBy, reviewed_at: new Date().toISOString(), matched_company_id: companyId,
  }).eq('id', row.id);
  if (error) throw error;
}

async function rejectImportRow(row, reviewedBy) {
  const { error } = await window.sb.from('import_rows').update({
    status: 'Rejected', reviewed_by: reviewedBy, reviewed_at: new Date().toISOString(),
  }).eq('id', row.id);
  if (error) throw error;
}

async function findCompanyMatch(domain, name) {
  if (domain) {
    const normalized = domain.toLowerCase().replace(/^https?:\/\//, '').replace(/^www\./, '').trim();
    const { data } = await window.sb.from('companies').select('id, company_name, domain').eq('domain', normalized).maybeSingle();
    if (data) return data;
  }
  if (name) {
    const { data } = await window.sb.from('companies').select('id, company_name, domain').ilike('company_name', name.trim()).limit(1);
    if (data && data.length) return data[0];
  }
  return null;
}

function stageBadge(stage) {
  const cls = stage === 'Won' ? 'badge-won' : stage === 'Lost' ? 'badge-lost' : 'badge-stage';
  return `<span class="badge ${cls}">${stage}</span>`;
}

function priorityBadge(priority) {
  return `<span class="badge badge-${priority}">${priority}</span>`;
}

function verificationBadge(status) {
  const cls = status === 'Verified' ? 'badge-verified' : status === 'Rejected' ? 'badge-rejected' : 'badge-pending';
  return `<span class="badge ${cls}">${status}</span>`;
}

function fmtDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

function fmtDateTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
}

function isOverdue(task) {
  return task.status === 'Open' && task.due_date && new Date(task.due_date) < new Date();
}
