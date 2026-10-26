const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const addon = fs.readFileSync(path.join(__dirname, '../assets/jm_direct_connection.js'), 'utf8');

function fixture(options = {}) {
    const state = {
        enabled: options.enabled ?? true, calls: [], registered: [],
        data: options.data || {}, settings: {apiDomain: '1', imageStream: '1', refreshDomainsOnStart: false, ...options.settings},
        get: async () => 'ok', post: async () => 'ok',
        fetch: async () => { throw new Error('Offline'); },
    };
    const context = vm.createContext({
        console, fetch: (...args) => state.fetch(...args),
        sendMessage: message => {
            if (message.action === 'enabled') return state.enabled;
            state.registered.push(message);
        }, UI: {showDialog: (...args) => { state.dialog = args; }, showMessage: () => {}},
        state,
    });
    vm.runInContext(`
        class JM {
            key = 'jm';
            static fallbackServers = ['old-a.example.org', 'old-b.example.org'];
            static imageUrl = 'https://cdn-msp.jmapinodeudzn.net';
            baseHeaders = {};
            get baseUrl() { return 'https://' + JM.apiDomains[Number(this.loadSetting('apiDomain')) - 1]; }
            loadSetting(key) { return state.settings[key]; }
            loadData(key) { return state.data[key]; }
            saveData(key, data) { state.data[key] = data; }
            convertData(value) { return value; }
            async get(url) { state.calls.push(['GET', url]); return state.get(url); }
            async post(url, body) { state.calls.push(['POST', url, body]); return state.post(url, body); }
            async refreshApiDomains() { state.calls.push(['originalRefresh']); }
            async refreshImgUrl() { state.calls.push(['originalImage']); }
            getImgHeaders() { return {'User-Agent': 'fixture'}; }
            async init() { state.calls.push(['originalInit']); }
            comic = {
                onImageLoad: url => ({modifyImage: 'original unscramble', headers: {Referer: 'original'}}),
                onThumbnailLoad: url => ({headers: {Referer: 'original'}}),
            };
        }
        globalThis.source = new JM();
        ${addon}
        JmNetwork.install(source);
    `, context);
    return {state, source: context.source, run: js => vm.runInContext(js, context)};
}

test('disabled mode preserves upstream init, requests and image configs', async () => {
    const {state, source} = fixture({enabled: false});
    await source.init();
    await source.get(source.baseUrl + '/search?q=x');
    const config = await source.comic.onImageLoad('https://example.org/p', '1', '1');
    assert.equal(config.modifyImage, 'original unscramble');
    assert.equal(config.url, undefined);
    assert.deepEqual(JSON.parse(JSON.stringify(state.calls)), [['originalInit'], ['GET', 'https://old-a.example.org/search?q=x']]);
});

test('cold start has usable domains with startup refresh disabled', async () => {
    const {state, source} = fixture();
    state.get = async () => JSON.stringify({img_host: 'https://img.example.org'});
    await source.init();
    assert.match(source.baseUrl, /^https:\/\/www\.cdnhjk\.net$/);
    assert.equal(state.data.jmNetwork.image, 'https://img.example.org');
});

test('corrupt configuration is skipped; a valid parallel bootstrap wins', async () => {
    const {state, source} = fixture();
    state.fetch = async url => ({status: 200, text: async () => url.includes('c03') ? 'corrupt JSON' :
        JSON.stringify({Server: ['API.EXAMPLE.ORG', '127.0.0.1', 'https://evil.org', 'api.example.org']})});
    await source.refreshApiDomains(false);
    assert.equal(source.baseUrl, 'https://api.example.org');
    assert.deepEqual(Array.from(state.data.jmNetwork.api), ['api.example.org']);
});

test('failed or empty bootstrap retains cached domains and image host', async () => {
    const {state, source} = fixture({data: {jmNetwork: {
        api: ['cached.example.org'], working: 'cached.example.org', image: 'https://img.example.org',
    }}});
    state.fetch = async () => ({status: 200, text: async () => '{"Server":[]}'});
    await source.refreshApiDomains(false);
    assert.equal(source.baseUrl, 'https://cached.example.org');
});

test('GET failover preserves query, caches success and follows manual API selection', async () => {
    const {state, source} = fixture();
    state.get = async url => {
        if (url.includes('cdnhjk')) throw 'DioException: connection timeout';
        return 'decoded by upstream';
    };
    const query = '/search?search_query=a%20b&page=2';
    assert.equal(await source.get(source.baseUrl + query), 'decoded by upstream');
    assert.equal(state.calls.length, 2);
    assert.equal(state.calls[1][1], 'https://www.cdngwc.cc' + query);
    assert.equal(source.baseUrl, 'https://www.cdngwc.cc');
    state.settings.apiDomain = '3';
    assert.equal(source.baseUrl, 'https://www.cdngwc.net');
    assert.equal(state.settings.apiDomain, '3');
});

test('GET retry is bounded and does not cover unknown endpoints', async () => {
    const {state, source} = fixture();
    state.get = async () => { throw 'Invalid Status Code: 503'; };
    await assert.rejects(source.get(source.baseUrl + '/search?q=x'), e => e === 'Invalid Status Code: 503');
    assert.equal(state.calls.length, 3);
    state.calls.length = 0;
    await assert.rejects(source.get(source.baseUrl + '/future-write-endpoint'), () => true);
    assert.equal(state.calls.length, 1);
});

test('authentication, rate limits and protocol errors never cause API replay', async () => {
    for (const error of ['Login expired', 'Invalid Status Code: 401', 'Invalid Status Code: 429',
        'Invalid Data', new SyntaxError('Malformed decrypted JSON')]) {
        const {state, source} = fixture();
        state.get = async () => { throw error; };
        await assert.rejects(source.get(source.baseUrl + '/search'), () => true);
        assert.equal(state.calls.length, 1);
    }
});

test('POSTs including login and favorites keep the original single request', async () => {
    const {state, source} = fixture();
    state.post = async () => { throw 'DioException: timed out after write'; };
    for (const endpoint of ['/login', '/favorite', '/comment']) {
        await assert.rejects(source.post(source.baseUrl + endpoint, 'fixture=true'), () => true);
    }
    assert.equal(state.calls.length, 3);
    assert.ok(state.calls.every(call => call[0] === 'POST'));
});

test('image stream changes apply before reading and preserve original transforms', async () => {
    const {state, source, run} = fixture();
    state.get = async url => JSON.stringify({img_host: url.includes('shunt=2') ?
        'https://img2.example.org' : 'https://img1.example.org'});
    await source.init();
    state.settings.imageStream = '2';
    const config = await source.comic.onImageLoad('https://old.example.org/media/photos/42/a.webp?q=1', '42', '42');
    assert.equal(config.url, 'https://img2.example.org/media/photos/42/a.webp?q=1');
    assert.equal(config.modifyImage, 'original unscramble');
    assert.equal(config.headers.Referer, 'original');
    state.settings.imageStream = '1';
    await run('JmNetwork.prepareImage(source)');
    assert.equal(source.comic.onThumbnailLoad('https://old.example.org/media/albums/42.jpg').url,
        'https://img1.example.org/media/albums/42.jpg');
});

test('parallel image preparation shares a single settings request', async () => {
    const {state, run} = fixture();
    state.get = async () => JSON.stringify({img_host: 'https://img.example.org'});
    await Promise.all([run('JmNetwork.prepareImage(source)'), run('JmNetwork.prepareImage(source)')]);
    assert.equal(state.calls.length, 1);
});

test('switching off after activation restores upstream request behavior', async () => {
    const {state, source} = fixture();
    assert.ok(source.baseUrl);
    state.enabled = false;
    state.get = async () => { throw 'DioException: connection reset'; };
    await assert.rejects(source.get(source.baseUrl + '/search'), () => true);
    assert.equal(state.calls.length, 1);
});

test('restart reuses a successful route only for the same saved selection', () => {
    const data = {jmNetwork: {api: ['a.example.org', 'b.example.org', 'c.example.org'],
        selected: '1', working: 'b.example.org'}};
    assert.equal(fixture({data}).source.baseUrl, 'https://b.example.org');
    assert.equal(fixture({data, settings: {apiDomain: '3'}}).source.baseUrl, 'https://c.example.org');
});

test('requests during startup wait for discovery and use the new list', async () => {
    const {state, source} = fixture({settings: {refreshDomainsOnStart: true}});
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    state.fetch = async () => {
        await gate;
        return {status: 200, text: async () => '{"Server":["new.example.org"]}'};
    };
    state.get = async () => JSON.stringify({img_host: 'https://img.example.org'});
    const initialization = source.init();
    const request = source.get(source.baseUrl + '/search?q=fixture');
    assert.equal(state.calls.length, 0);
    release();
    await Promise.all([initialization, request]);
    assert.ok(state.calls.every(call => call[1].startsWith('https://new.example.org/')));
});

test('an unreachable image setting uses the cached pool without retrying every cover', async () => {
    const {state, run} = fixture();
    state.get = async () => { throw 'DioException: connection reset'; };
    await run('JmNetwork.prepareImage(source)');
    const attempts = state.calls.length;
    await run('JmNetwork.prepareImage(source)');
    assert.equal(state.calls.length, attempts);
    state.settings.imageStream = '2';
    await run('JmNetwork.prepareImage(source)');
    assert.ok(state.calls.length > attempts);
});
