const ID = /^[A-Za-z0-9_-]{1,200}$/;
const DRIVE = 'https://www.googleapis.com/drive/v3/files';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'Range, If-None-Match',
  'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Accept-Ranges, ETag',
};
const collator = new Intl.Collator('en', { numeric: true, sensitivity: 'base' });
const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status, headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': status === 200 ? 'public, max-age=60' : 'no-store' },
});
const fail = (message, status) => json({ error: { message } }, status);
const typeOf = mime => mime === 'application/vnd.google-apps.folder' ? 'folder' : mime === 'application/pdf' ? 'pdf' : mime?.startsWith('image/') ? 'image' : 'unknown';

function resourceHeaders(env, fileId, resourceKey) {
  const key = resourceKey || (fileId === env.ROOT_FOLDER_ID ? env.ROOT_RESOURCE_KEY : null);
  return key ? { 'X-Goog-Drive-Resource-Keys': `${fileId}/${key}` } : {};
}

async function library(url, env, upstream) {
  const folder = url.searchParams.get('folderId') || env.ROOT_FOLDER_ID;
  const resourceKey = url.searchParams.get('resourceKey');
  if (!ID.test(folder || '') || (resourceKey && !ID.test(resourceKey))) return fail('Invalid folder ID or resource key.', 400);
  let token;
  const files = [];
  const seenTokens = new Set();
  do {
    const drive = new URL(DRIVE);
    drive.search = new URLSearchParams({
      q: `'${folder}' in parents and trashed=false`,
      fields: 'nextPageToken,incompleteSearch,files(id,name,mimeType,resourceKey,imageMediaMetadata(width,height))',
      orderBy: 'name_natural', pageSize: '1000', key: env.DRIVE_API_KEY,
    });
    if (token) drive.searchParams.set('pageToken', token);
    const response = await upstream(drive, { headers: resourceHeaders(env, folder, resourceKey) });
    if (!response.ok) return fail(response.status === 403 ? 'Drive denied access. Check the API key, quota, and folder sharing.' : 'The Drive library request failed.', response.status);
    let body;
    try { body = await response.json(); } catch { return fail('Drive returned invalid library data.', 502); }
    if (!Array.isArray(body.files) || body.incompleteSearch) return fail('Drive returned an incomplete library listing.', 502);
    for (const file of body.files) {
      const type = typeOf(file.mimeType);
      if (type === 'unknown' || !ID.test(file.id || '')) continue;
      const item = { id: file.id, name: typeof file.name === 'string' ? file.name : 'Untitled', type };
      if (ID.test(file.resourceKey || '')) item.resourceKey = file.resourceKey;
      const width = Number(file.imageMediaMetadata?.width), height = Number(file.imageMediaMetadata?.height);
      if (Number.isFinite(width) && width > 0 && Number.isFinite(height) && height > 0) Object.assign(item, { width, height });
      files.push(item);
    }
    token = body.nextPageToken;
    if (token && (typeof token !== 'string' || seenTokens.has(token))) return fail('Drive pagination could not complete.', 502);
    if (token) seenTokens.add(token);
    // Cloudflare request subrequest limits vary by account. Fail visibly instead of truncating.
    if (token && seenTokens.size >= 40) return fail('This folder is too large for one request. Split it into chapter folders.', 413);
  } while (token);
  const unique = [...new Map(files.map(file => [file.id, file])).values()];
  unique.sort((a, b) => (a.type === 'folder' ? 0 : 1) - (b.type === 'folder' ? 0 : 1) || collator.compare(a.name, b.name) || a.id.localeCompare(b.id));
  return json(unique);
}

async function page(request, url, env, upstream) {
  const fileId = url.searchParams.get('fileId'), key = url.searchParams.get('resourceKey');
  if (!ID.test(fileId || '') || (key && !ID.test(key))) return fail('Invalid file ID or resource key.', 400);
  const drive = new URL(`${DRIVE}/${fileId}`);
  drive.search = new URLSearchParams({ alt: 'media', key: env.DRIVE_API_KEY });
  const headers = new Headers(resourceHeaders(env, fileId, key));
  for (const name of ['Range', 'If-None-Match']) if (request.headers.has(name)) headers.set(name, request.headers.get(name));
  const response = await upstream(drive, { method: request.method, headers });
  if (!response.ok && ![304, 416].includes(response.status)) return fail('Unable to download this file. Check Drive sharing and quota.', response.status);
  const output = new Headers(CORS);
  for (const name of ['Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges', 'ETag', 'Last-Modified']) {
    if (response.headers.has(name)) output.set(name, response.headers.get(name));
  }
  if (!output.has('Content-Type')) output.set('Content-Type', 'application/octet-stream');
  output.set('Cache-Control', response.status === 416 ? 'no-store' : 'public, max-age=3600');
  return new Response(request.method === 'HEAD' || response.status === 304 ? null : response.body, { status: response.status, headers: output });
}

export async function handleRequest(request, env, upstream = fetch) {
  const url = new URL(request.url);
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (!['GET', 'HEAD'].includes(request.method)) return fail('Method not allowed.', 405);
  if (!['/api/library', '/api/page'].includes(url.pathname)) return fail('Not found.', 404);
  if (!env.DRIVE_API_KEY || !ID.test(env.ROOT_FOLDER_ID || '')) return fail('Worker configuration is missing. Set DRIVE_API_KEY and ROOT_FOLDER_ID.', 503);
  try {
    if (url.pathname === '/api/page') return await page(request, url, env, upstream);
    const response = await library(url, env, upstream);
    return request.method === 'HEAD' ? new Response(null, { status: response.status, headers: response.headers }) : response;
  } catch { return fail('The cloud request could not complete. Try again.', 502); }
}

export default { fetch(request, env) { return handleRequest(request, env); } };
