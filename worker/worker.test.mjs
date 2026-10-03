import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { handleRequest } from './worker.mjs';

const env = { DRIVE_API_KEY: 'test-key', ROOT_FOLDER_ID: 'root-folder' };
const request = (path = '/api/library', options) => new Request(`https://worker.example${path}`, options);
const response = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
const file = (id, name, mimeType = 'image/jpeg') => ({ id, name, mimeType });

test('natural page order and supported file routing', async () => {
  const result = await handleRequest(request(), env, async () => response({ files: [file('ten', '10.jpg'), file('two', '2.jpg'), file('pdf', 'Volume.pdf', 'application/pdf'), file('folder', 'Series', 'application/vnd.google-apps.folder'), file('other', 'note.txt', 'text/plain')] }));
  assert.equal(result.status, 200); assert.deepEqual((await result.json()).map(x => [x.id, x.type]), [['folder','folder'], ['two','image'], ['ten','image'], ['pdf','pdf']]);
});
test('follows all Drive pages including empty intermediate pages', async () => {
  let calls = 0;
  const result = await handleRequest(request(), env, async url => {
    calls++; assert.equal(url.searchParams.get('key'), 'test-key'); assert.equal(url.searchParams.get('q'), "'root-folder' in parents and trashed=false");
    if (calls === 1) return response({ files: [file('one', '1.jpg')], nextPageToken: 'next' });
    assert.equal(url.searchParams.get('pageToken'), calls === 2 ? 'next' : 'last');
    return calls === 2 ? response({ files: [], nextPageToken: 'last' }) : response({ files: [file('two', '2.jpg')] });
  });
  assert.equal(calls, 3); assert.equal((await result.json()).length, 2);
});
test('passes nested folder and resource key', async () => {
  const result = await handleRequest(request('/api/library?folderId=nested&resourceKey=abc_123'), env, async (url, options) => {
    assert.equal(url.searchParams.get('q'), "'nested' in parents and trashed=false"); assert.equal(options.headers['X-Goog-Drive-Resource-Keys'], 'nested/abc_123'); return response({files:[]});
  }); assert.deepEqual(await result.json(), []);
});
test('passes configured root resource key', async () => {
  await handleRequest(request(), {...env, ROOT_RESOURCE_KEY:'root-key'}, async (url, options) => { assert.equal(options.headers['X-Goog-Drive-Resource-Keys'], 'root-folder/root-key'); return response({files:[]}); });
});
test('returns image dimensions and per-file resource keys', async () => {
  const result = await handleRequest(request(), env, async () => response({files:[{...file('image','spread.jpg'), imageMediaMetadata:{width:'1600', height:'1000'}, resourceKey:'resource-key'}]}));
  assert.deepEqual(await result.json(), [{id:'image',name:'spread.jpg',type:'image',resourceKey:'resource-key',width:1600,height:1000}]);
});
test('rejects missing worker configuration', async () => { const result = await handleRequest(request(), {}); assert.equal(result.status,503); assert.match((await result.json()).error.message,/configuration/); });
test('rejects query injection before contacting Drive', async () => { let called=false; const result = await handleRequest(request('/api/library?folderId=x%27%20or%20true'),env,async()=>{called=true;}); assert.equal(result.status,400); assert.equal(called,false); });
test('rejects an invalid root folder', async () => { assert.equal((await handleRequest(request(),{...env,ROOT_FOLDER_ID:"root'"})).status,503); });
test('does not turn Drive access errors into an empty library', async () => { const result = await handleRequest(request(),env,async()=>response({error:{message:'sensitive key value'}},403)); assert.equal(result.status,403); const text=await result.text(); assert.match(text,/denied/); assert.doesNotMatch(text,/sensitive|test-key/); assert.equal(result.headers.get('Cache-Control'),'no-store'); });
test('rejects malformed Drive data', async () => { assert.equal((await handleRequest(request(),env,async()=>new Response('broken'))).status,502); });
test('rejects incomplete searches', async () => { assert.equal((await handleRequest(request(),env,async()=>response({files:[],incompleteSearch:true}))).status,502); });
test('detects repeated pagination tokens', async () => { assert.equal((await handleRequest(request(),env,async()=>response({files:[],nextPageToken:'repeat'}))).status,502); });
test('deduplicates repeated files between pages', async () => { let calls=0; const result=await handleRequest(request(),env,async()=>response({files:[file('same','1.jpg')],...(calls++===0?{nextPageToken:'next'}:{})})); assert.equal((await result.json()).length,1); });
test('handles network failure without leaking upstream detail', async () => { const result = await handleRequest(request(),env,async()=>{throw new Error('test-key');}); assert.equal(result.status,502); assert.doesNotMatch(await result.text(),/test-key/); });
test('streams partial downloads with range headers and MIME type', async () => {
  const result=await handleRequest(request('/api/page?fileId=page-id',{headers:{Range:'bytes=0-2'}}),env,async(url,options)=>{
    assert.equal(url.pathname,'/drive/v3/files/page-id'); assert.equal(url.searchParams.get('alt'),'media'); assert.equal(options.headers.get('Range'),'bytes=0-2');
    return new Response('abc',{status:206,headers:{'Content-Type':'image/jpeg','Content-Range':'bytes 0-2/100','Accept-Ranges':'bytes',ETag:'version'}});
  }); assert.equal(result.status,206); assert.equal(result.headers.get('Content-Range'),'bytes 0-2/100'); assert.equal(result.headers.get('Content-Type'),'image/jpeg'); assert.equal(await result.text(),'abc');
});
test('preserves failed download status', async()=>{const result=await handleRequest(request('/api/page?fileId=page'),env,async()=>response({error:{}},404)); assert.equal(result.status,404); assert.equal(result.headers.get('Cache-Control'),'no-store');});
test('requires a media file ID', async()=>{assert.equal((await handleRequest(request('/api/page'),env)).status,400);});
test('preflight works without a secret', async()=>{const result=await handleRequest(request('/api/page',{method:'OPTIONS'}),{}); assert.equal(result.status,204); assert.match(result.headers.get('Access-Control-Allow-Headers'),/Range/);});
test('unsupported methods do not call Drive', async()=>{assert.equal((await handleRequest(request('/api/library',{method:'POST'}),env)).status,405);});
test('unknown routes are 404', async()=>{assert.equal((await handleRequest(request('/unknown'),env)).status,404);});
test('HEAD media requests have no response body', async()=>{const result=await handleRequest(request('/api/page?fileId=page',{method:'HEAD'}),env,async(url,options)=>{assert.equal(options.method,'HEAD');return new Response(null,{headers:{'Content-Type':'application/pdf','Content-Length':'100'}});}); assert.equal(await result.text(),'');assert.equal(result.headers.get('Content-Length'),'100');});
test('HEAD library requests have no response body', async()=>{const result=await handleRequest(request('/api/library',{method:'HEAD'}),env,async()=>response({files:[]}));assert.equal(result.status,200);assert.equal(await result.text(),'');});
test('Cloudflare fetch entrypoint ignores the execution context argument', async()=>{const old=globalThis.fetch;try{globalThis.fetch=async()=>response({files:[]});const result=await worker.fetch(request(),env,{waitUntil(){}});assert.equal(result.status,200);}finally{globalThis.fetch=old;}});
test('304 and 416 retain their original statuses', async()=>{for(const status of [304,416]){const result=await handleRequest(request('/api/page?fileId=page'),env,async()=>new Response(null,{status,headers:{'Content-Range':'bytes */100'}}));assert.equal(result.status,status);if(status===416)assert.equal(result.headers.get('Cache-Control'),'no-store');}});
