/* JM 1.4 compatibility layer. Keep upstream protocol, IDs and image decoding.
 * Domain discovery follows hect0x7/JMComic-Crawler-Python (MIT),
 * jm_config.py at fd8953025db5b844f1b7f025d063f544e61a2dbd.
 */
const JmNetwork = (() => {
    const fallback = [
        'www.cdnhjk.net', 'www.cdngwc.cc', 'www.cdngwc.net', 'www.cdngwc.club',
    ];
    const bootstrap = [
        'rup4a04-c03.tos-cn-beijing.bytepluses.com.cn',
        'rup4a04-c02.tos-cn-hongkong.bytepluses.com',
        'rup4a04-c01.tos-ap-southeast-1.bytepluses.com',
    ];
    const enabled = () => sendMessage({method: 'jmNetwork', action: 'enabled'}) === true;
    const domain = value => typeof value === 'string' && value.length <= 253 &&
        /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*$/i.test(value);
    const domains = values => Array.isArray(values)
        ? [...new Set(values.filter(domain).map(value => value.toLowerCase()))].slice(0, 16) : [];
    const hostOf = url => /^https:\/\/([^/:?#]+)(?:[/?#]|$)/i.exec(url)?.[1]?.toLowerCase();
    const pathOf = url => /^https:\/\/[^/]+(\/[^?#]*)/.exec(url)?.[1];
    const replaceHost = (url, host) => url.replace(/^(https:\/\/)[^/]+/, '$1' + host);
    const register = (api, images = []) => sendMessage({method: 'jmNetwork', action: 'register', api, images});
    const retryable = error => /DioException|Rhttp.*Exception|SocketException|TimeoutException|Connection (?:reset|closed|refused)|Invalid Status Code: (?:408|500|502|503|504)\b/i.test(String(error));
    const readPath = path => /^\/(setting|promote|categories\/filter|week(?:\/filter)?|search|favorite|album|chapter|forum|daily)$/.test(path || '');

    function install(source) {
        if (source?.key !== 'jm' || source._jmNetworkInstalled) return;
        const C = source.constructor;
        // Custom JM sources keep their own transport contract.
        if (!Array.isArray(C.fallbackServers) || !['init', 'get', 'refreshApiDomains',
            'refreshImgUrl', 'convertData', 'getImgHeaders'].every(name => typeof source[name] === 'function') ||
            !Object.getOwnPropertyDescriptor(C.prototype, 'baseUrl')?.get) return;
        source._jmNetworkInstalled = true;
        C.apiDomains = C.apiDomains || [...C.fallbackServers];
        const original = {
            init: source.init.bind(source), get: source.get.bind(source),
            refreshApi: source.refreshApiDomains.bind(source),
            refreshImage: source.refreshImgUrl.bind(source),
            baseUrl: Object.getOwnPropertyDescriptor(C.prototype, 'baseUrl').get.bind(source),
        };
        let hydrated = false, discovery = null, imageRefresh = null, initialDiscovery = null;
        let failedImageStream = null, imageRetryAfter = 0;
        let saved = {}, working = null, selected = null, imageStream = null;
        const failedApi = new Map();
        function hydrate() {
            if (hydrated) return;
            hydrated = true;
            saved = source.loadData('jmNetwork') || {};
            C.apiDomains = domains(saved.api).length ? domains(saved.api) : [...fallback];
            selected = source.loadSetting('apiDomain');
            working = saved.selected === selected && C.apiDomains.includes(saved.working) ? saved.working : null;
            if (hostOf(saved.image) && domain(hostOf(saved.image))) C.imageUrl = 'https://' + hostOf(saved.image);
            register(C.apiDomains, hostOf(C.imageUrl) ? [hostOf(C.imageUrl)] : []);
        }
        function persist() {
            source.saveData('jmNetwork', {
                api: C.apiDomains, working, selected, image: C.imageUrl,
            });
        }
        function preferred() {
            const value = source.loadSetting('apiDomain');
            if (selected !== value) {
                if (selected !== null) { working = null; failedApi.clear(); }
                selected = value;
            }
            return C.apiDomains[Number(value) - 1] || C.apiDomains[0];
        }
        Object.defineProperty(source, 'baseUrl', {get() {
            if (!enabled()) return original.baseUrl();
            hydrate();
            const host = preferred();
            return 'https://' + (working || host);
        }});
        async function discover() {
            if (discovery) return discovery;
            discovery = (async () => {
                // A corrupt or blocked bootstrap must not discard the cached list.
                // Run all three concurrently; resolve on the first valid list.
                const found = await new Promise(resolve => {
                    let remaining = bootstrap.length;
                    for (const host of bootstrap) {
                        (async () => {
                            try {
                                const response = await fetch('https://' + host + '/newsvr-2025.txt',
                                    {headers: source.baseHeaders});
                                if (response.status !== 200) return;
                                const config = JSON.parse(source.convertData(await response.text(), 'diosfjckwpqpdfjkvnqQjsik'));
                                const list = domains(config.Server);
                                if (list.length) resolve(list);
                            } catch (_) {
                                // Try the other official configuration endpoints.
                            } finally {
                                if (--remaining === 0) resolve(null);
                            }
                        })();
                    }
                });
                return found;
            })();
            try { return await discovery; } finally { discovery = null; }
        }
        source.refreshApiDomains = async showDialog => {
            if (!enabled()) return original.refreshApi(showDialog);
            hydrate();
            const found = await discover();
            const apply = () => {
                if (found) {
                    C.apiDomains = found;
                    if (!found.includes(working)) working = null;
                    register(found);
                    persist();
                }
            };
            if (showDialog) {
                UI.showDialog(found ? 'Update Success' : 'Update Failed',
                    (found || C.apiDomains).join('\n'), [
                        {text: 'Cancel', callback: () => {}},
                        {text: 'Apply', callback: async () => {
                            apply();
                            await source.refreshImgUrl(true);
                        }},
                    ]);
            } else apply();
        };
        source.get = async url => {
            if (!enabled()) return original.get(url);
            hydrate();
            if (initialDiscovery) await initialDiscovery;
            const preferredHost = preferred();
            const host = hostOf(url);
            if (![...C.apiDomains, ...fallback, ...C.fallbackServers].includes(host) || !readPath(pathOf(url))) return original.get(url);
            // Three attempts, no write replay. Do not retry authentication, rate
            // limits, protocol/JSON errors or other application responses.
            const pool = [...new Set([working || preferredHost, host, ...C.apiDomains])];
            const healthy = pool.filter(candidate => (failedApi.get(candidate) || 0) <= Date.now());
            const candidates = (healthy.length ? healthy : pool).slice(0, 3);
            let lastError;
            for (const candidate of candidates) {
                try {
                    const result = await original.get(replaceHost(url, candidate));
                    failedApi.delete(candidate);
                    if (working !== candidate) { working = candidate; persist(); }
                    return result;
                } catch (error) {
                    if (!retryable(error)) throw error;
                    failedApi.set(candidate, Date.now() + 60000);
                    if (working === candidate) working = null;
                    lastError = error;
                }
            }
            throw lastError;
        };
        source.refreshImgUrl = async showMessage => {
            if (!enabled()) return original.refreshImage(showMessage);
            hydrate();
            if (imageRefresh) return imageRefresh;
            const stream = source.loadSetting('imageStream');
            imageRefresh = (async () => {
                const result = JSON.parse(await source.get(source.baseUrl +
                    '/setting?app_img_shunt=' + stream + '&express='));
                const host = hostOf(result.img_host);
                if (!host || !domain(host)) throw new Error('Invalid JM image host');
                C.imageUrl = 'https://' + host;
                register([], [host]);
                imageStream = stream;
                persist();
                if (showMessage) UI.showMessage('Image Stream ' + stream + ':\n' + host);
            })();
            try { return await imageRefresh; } finally { imageRefresh = null; }
        };
        // Existing chapter URLs and thumbnail keys remain valid; host selection
        // happens immediately before each image request, preserving its path.
        function imageConfig(url, config) {
            if (!enabled()) return config;
            hydrate();
            const path = pathOf(config.url || url);
            if (path && /^\/media\/(albums|photos|users)\//.test(path)) {
                config = {...config, url: replaceHost(config.url || url, hostOf(C.imageUrl)),
                    headers: {...source.getImgHeaders(), ...config.headers}};
            }
            return config;
        }
        if (source.comic?.onImageLoad) {
            const load = source.comic.onImageLoad.bind(source.comic);
            source.comic.onImageLoad = async (url, cid, eid) => {
                await source._jmPrepareImage();
                return imageConfig(url, await load(url, cid, eid));
            };
        }
        source._jmPrepareImage = async () => {
            if (!enabled()) return;
            const stream = source.loadSetting('imageStream');
            if (failedImageStream === stream && Date.now() < imageRetryAfter) return;
            if (imageStream !== stream) {
                try {
                    await source.refreshImgUrl(false);
                    // A user can change the selected stream while this is loading.
                    if (imageStream !== source.loadSetting('imageStream')) await source.refreshImgUrl(false);
                } catch (_) {
                    failedImageStream = stream;
                    imageRetryAfter = Date.now() + 60000;
                }
            }
        };
        if (source.comic?.onThumbnailLoad) {
            const load = source.comic.onThumbnailLoad.bind(source.comic);
            source.comic.onThumbnailLoad = url => imageConfig(url, load(url));
        }
        source.init = async () => {
            if (!enabled()) return original.init();
            hydrate();
            try {
                if (source.loadSetting('refreshDomainsOnStart')) {
                    initialDiscovery = source.refreshApiDomains(false);
                    try { await initialDiscovery; } finally { initialDiscovery = null; }
                }
                await source.refreshImgUrl(false);
            } catch (_) {
                console.warn('JM initialization failed; retaining cached and built-in routes.');
            }
        };
    }
    return {install, prepareImage: source => source?._jmPrepareImage?.()};
})();
