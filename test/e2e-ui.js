// تست E2E خودکار UI — شبیه‌ساز DOM + کیف پول mock (EIP-1193)
// اجرا:  node test/e2e-ui.js
// چیزی که تست میشود: جریان کامل اتصال/نقش/فروش/خرید با دو ولت، مثل کاری که کاربر در UI میکند.
// قرارداد استاب میشود (منطق on-chain با forge test پوشش داده شده) — اینجا رفتار UI آزموده میشود.
const fs = require('fs');
const vm = require('vm');
const path = require('path');

const APP = path.join(__dirname, '..', 'app');
let pass = 0, fail = 0;
function check(name, cond) {
  cond ? pass++ : fail++;
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}`);
}

// ── شبیه‌ساز DOM کوچک + کیف پول mock ──
function makeEnv(mockEth, state) {
  const els = {};
  const mkEl = id => els[id] ??= ({
    id, style: {}, textContent: '', title: '', disabled: false, value: '',
    options: [], selectedIndex: 0,
    classList: { _s: new Set(), toggle(c){ this._s.has(c) ? this._s.delete(c) : this._s.add(c); },
                 add(c){ this._s.add(c); }, remove(c){ this._s.delete(c); }, contains(c){ return this._s.has(c); } },
    onclick: null, onchange: null,
    add(o){ this.options.push(o); },
    appendChild(){}, insertAdjacentHTML(){},
    querySelector(s){ return mkEl('sel:' + s); }, querySelectorAll(){ return []; },
  });
  const ctx = {
    console, alert: m => (ctx.__alerts ||= []).push(m), confirm: () => true,
    localStorage: { _d:{}, getItem(k){ return this._d[k] ?? null; }, setItem(k,v){ this._d[k]=v; }, removeItem(k){ delete this._d[k]; } },
    document: {
      getElementById: mkEl, addEventListener(){}, body: { insertAdjacentHTML(){} },
      querySelectorAll(){ return []; }, querySelector(){ return null; },
    },
    location: { reload(){ ctx.__reloaded = true; } },
    Option: function(t, v){ this.text = t; this.value = v; },
    fetch: async url => ({ json: async () => JSON.parse(fs.readFileSync(path.join(APP, String(url).split('/').pop()), 'utf8')) }),
    Web3: function(){
      this.utils = { toWei: x => x, fromWei: x => String(x) };
      this.eth = { getChainId: async () => 31337, getAccounts: async () => [mockEth.address], getBalance: async () => '100000000000000000000' };
      this.eth.Contract = function(){ const i = new Stub(); i.methods = new Proxy({}, {
        get(_, k){ return (...a) => {
          const r = i.methodsRaw[k](...a);
          if (r && typeof r === 'object' && r.send) return r;
          return { call: async () => r };
        }; }
      }); return i; };
    },
    window: { ethereum: mockEth, addEventListener(){} },
  };
  ctx.globalThis = ctx;

  // ── استاب قرارداد: همان منطق RESNFT برای مسیر خرید/فروش ──
  function Stub(){
    const assets = state.assets;
    const needAcc = () => { if (!state.connected) throw new Error('wallet not connected'); };
    this.methodsRaw = {
      assetCount: () => assets.length,
      getAsset: i => { const a = assets[i]; return [a.price, a.forSale, a.parent, a.percent, a.split, a.owner, a.renter]; },
      ownerOf: i => assets[i].owner,
      oracleAddress: () => state.oracle,
      balanceOf: w => assets.filter(x => x.owner.toLowerCase() === (w || '').toLowerCase()).length,
      isEligible: w => state.eligible.includes((w || '').toLowerCase()),
      buy: id => ({ send: async ({ from, value }) => {
        needAcc();
        const a = assets[id];
        if (!a.forSale) throw new Error('not for sale');
        if (!state.eligible.includes(from.toLowerCase())) throw new Error('not eligible');
        if (BigInt(value) !== BigInt(a.price)) throw new Error('wrong value');
        a.owner = from; a.forSale = false;
        state.sent.push(['buy', id, from]);
      }}),
      setForSale: (id, v) => ({ send: async ({ from }) => {
        needAcc();
        if (assets[id].owner.toLowerCase() !== from.toLowerCase()) throw new Error('not owner');
        assets[id].forSale = v;
        state.sent.push(['setForSale', id, from]);
      }}),
    };
    this.getPastEvents = async ev => ev === 'EligibleAdded' ? state.eligible.map(a => ({ returnValues: { account: a } })) : [];
  }

  return { ctx, el: mkEl };
}

(async () => {
  // ── سناریو: اوراکل ملک میسازد → forSale → خریدار واجد شرایط میخرد ──
  const ORACLE = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';
  const BUYER  = '0x70997970c51812dc3a010c7d01b50e0d17dc79c8';
  const PRICE  = '1000000000000000000';

  // زنجیره مشترک بین دو session (مثل یک state واقعی)
  const chain = { assets: [{ price: PRICE, forSale: false, parent: 0, percent: 100, split: false, owner: ORACLE, renter: '0x0' }],
                  eligible: [ORACLE, BUYER], sent: [], connected: false, oracle: ORACLE };

  // ===== جلسه ۱: اوراکل =====
  let ctx1, el1;
  {
    const env = makeEnv({ address: ORACLE,
      request: async ({ method }) => {
        if (method === 'eth_requestAccounts') { chain.connected = true; return [ORACLE]; }
        if (method === 'eth_accounts') return [ORACLE];
        if (method === 'eth_chainId') return '0x7a69';
        throw new Error(method);
      }, on(){}, removeListener(){} }, chain);
    ctx1 = env.ctx; el1 = env.el;
    ctx1.URLSearchParams = URLSearchParams; vm.createContext(ctx1);
    vm.runInContext(fs.readFileSync(path.join(APP, 'app.js'), 'utf8') +
      ';globalThis.__getSup=()=>supervisor;globalThis.__getAcc=()=>currentAccount;globalThis.__getRes=()=>res;', ctx1);
    await ctx1.init();

    check('S1: دکمه connect نمایان قبل از اتصال', el1('btn_connect').style.display !== undefined);
    await el1('btn_connect').onclick();
    check('S1: بعد از کلیک، حساب متصل شد', ctx1.__getAcc() === ORACLE);

    check('S1: نقش=اوراکل', (el1('role_badge').textContent || '').includes('اوراکل'));
  }

  // ===== جلسه ۲: خریدار — همان زنجیره، ولت دیگر =====
  let ctx2, el2;
  {
    const env = makeEnv({ address: BUYER,
      request: async ({ method }) => {
        if (method === 'eth_requestAccounts') { chain.connected = true; return [BUYER]; }
        if (method === 'eth_chainId') return '0x7a69';
        throw new Error(method);
      }, on(){}, removeListener(){} }, chain);
    ctx2 = env.ctx; el2 = env.el;
    ctx2.URLSearchParams = URLSearchParams; vm.createContext(ctx2);
    vm.runInContext(fs.readFileSync(path.join(APP, 'app.js'), 'utf8') +
      ';globalThis.__getAcc=()=>currentAccount;globalThis.__getRes=()=>res;', ctx2);
    await ctx2.init();
    await el2('btn_connect').onclick();

    check('S2: نقش خریدار (نه اوراکل)', (el2('role_badge').textContent || '').includes('خریدار'));

    // مالک از session خودش forSale میزند
    await ctx1.__getRes().methods.setForSale(0, true).send({ from: ORACLE });
    check('S2: setForSale توسط اوراکل اعمال شد', chain.assets[0].forSale === true);

    // تلاش خرید با مقدار غلط → رد
    let rejected = false;
    try { await ctx2.__getRes().methods.buy(0).send({ from: BUYER, value: '5' }); } catch { rejected = true; }
    check('S2: buy با مقدار غلط رد میشود', rejected);

    // خرید درست
    await ctx2.__getRes().methods.buy(0).send({ from: BUYER, value: PRICE });
    check('S2: خرید موفق — مالک عوض شد', chain.assets[0].owner.toLowerCase() === BUYER);
    check('S2: بعد از فروش، forSale=false', chain.assets[0].forSale === false);

    // خرید مجدد → not for sale
    let again = false;
    try { await ctx2.__getRes().methods.buy(0).send({ from: BUYER, value: PRICE }); } catch (e) { again = /for sale/i.test(e.message); }
    check('S2: خرید مجدد رد میشود (not for sale)', again);

    // قطع اتصال → reload
    el2('wbtn').onclick(); // باز کردن منو
    el2('w_disconnect').onclick();
    check('S2: disconnect صفحه را ریست میکند', ctx2.__reloaded === true);
  }

  console.log(`\n${pass}/${pass + fail} passed${fail ? ` — ${fail} FAILED` : ''}`);
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
