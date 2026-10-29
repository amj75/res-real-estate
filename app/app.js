// RES v4 frontend — web3.js v4، پنل‌های نقش‌محور (اوراکل کشور/مالک/خریدار) + شورای کشورها (DAO)
// v4: هر کشور اوراکل خودش را دارد (countryOf)، هر اقدام اوراکل مرجع پرونده ثبتی (caseRef) میخواهد
// دسترسی: تب‌های نامرتبط برای هر نقش کاملاً حذف میشوند (نه فقط قفل) + require های on-chain لایه دوم
// RPC و شبکه از URL قابل تنظیم: app.html?rpc=https://...&chain=11155111&chainName=Sepolia
// پیش‌فرض: Anvil لوکال
const Q = new URLSearchParams((globalThis.location && location.search) || '');
const RPC_URL = Q.get('rpc') || 'http://localhost:8545';
const CHAIN_ID_DEC = Q.get('chain') || '31337';
const CHAIN_NAME = Q.get('chainName') || 'Anvil Local';
const CONTRACT = Q.get('contract') || localStorage.getItem('res_contract') || '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512';

let web3, res, council, currentAccount, supervisor, ABI, COUNCIL_ABI;
let myCountry = 0;       // کشورِ اوراکلی که الان وصل است (۰ = اوراکل نیست)
let myCountryActive = false;
// نام نمایشی چند کد ISO 3166 عددی؛ بقیه با خود کد نمایش داده میشوند
const COUNTRY_NAMES = { 364: 'ایران', 276: 'آلمان', 792: 'ترکیه', 784: 'امارات', 250: 'فرانسه', 826: 'بریتانیا', 840: 'آمریکا' };
const countryName = (c) => COUNTRY_NAMES[c] ? `${COUNTRY_NAMES[c]} (${c})` : `کشور ${c}`;
const ZERO = '0x0000000000000000000000000000000000000000';
let myAssets = []; // شناسه دارایی‌های اکانت فعلی
let walletConnected = false; // آیا کاربر کیف پول وصل کرده؟

const $id = (x) => document.getElementById(x);
const toWei = (eth) => web3.utils.toWei(eth, 'ether');
const fromWei = (w) => web3.utils.fromWei(w, 'ether');

async function init() {
  // وب۳ فقط-خواندنی برای نمایش داده‌ها؛ اتصال کیف پول فقط با کلیک کاربر
  ABI = (await (await fetch('RESNFT.json')).json()).abi;
  COUNCIL_ABI = (await (await fetch('OracleCouncil.json')).json()).abi;
  web3 = new Web3(RPC_URL);
  res = new web3.eth.Contract(ABI, CONTRACT);

  setupWalletWidget();
  // supervisor قبل از هر refresh باید خوانده شود — وگرنه refresh با supervisor=undefined می‌ترکد
  try {
    supervisor = await res.methods.oracleAddress().call();
  } catch (e) {
    alert('RPC در دسترس نیست: ' + RPC_URL + '\n' + (e.message || e));
    throw e;
  }
  if (window.ethereum) {
    // اگر قبلاً متصل بوده (permission ماندگار)، بدون پاپ‌آپ وصل شو
    if (localStorage.getItem('res_wallet_connected') === '1') await connectWallet(true);
  }

  bind();
  await refresh();
}

// ── ویجت کیف پول: Connect → dropdown (آدرس | تعویض | قطع) ──
function setupWalletWidget() {
  const btn = $id('btn_connect');
  btn.style.display = '';
  btn.disabled = !window.ethereum; // بدون MetaMask دکمه غیرفعال + توضیح
  btn.title = window.ethereum ? '' : 'کیف پول (مثل MetaMask) نصب نیست';
  btn.onclick = () => connectWallet(false);

  $id('wbtn').onclick = () => $id('wmenu').classList.toggle('open');
  document.addEventListener('click', e => {
    if (!e.target.closest('.wdrop')) $id('wmenu').classList.remove('open');
  });

  // تعویض: مجوز فعلی لغو → درخواست اتصال دوباره → پاپ‌آپ انتخاب حساب MetaMask باز میشود
  // (wallet_requestPermissions روی سایتِ متصل بی‌صدا resolve میشود؛ به همین دلیل قبلاً هیچ اتفاقی نمی‌افتاد)
  $id('w_switch').onclick = async () => {
    const eth = window.ethereum;
    $id('wmenu').classList.remove('open');
    try {
      await eth.request({ method: 'wallet_revokePermissions', params: [{ eth_accounts: {} }] }).catch(() => {});
      const accs = await eth.request({ method: 'eth_requestAccounts' }); // حالا با پاپ‌آپ
      if (!accs || !accs.length) return; // کاربر رد کرد — بمانیم بدون اتصال
      currentAccount = accs[0];
      localStorage.setItem('res_wallet_connected', '1');
      updateWbtn();
      await refresh();
    } catch (e) { console.error(e); }
  };

  // قطع اتصال: فقط state محلی — MetaMask API اجازه revoke نمیدهد
  $id('w_disconnect').onclick = () => {
    $id('wmenu').classList.remove('open');
    localStorage.removeItem('res_wallet_connected');
    location.reload(); // برگشت به حالت «اتصال کیف پول»
  };
}

async function connectWallet(silent) {
  if (!window.ethereum) return alert('کیف پول وب (MetaMask و…) پیدا نشد');
  try {
    const accs = silent
      ? await window.ethereum.request({ method: 'eth_accounts' })          // بدون پاپ‌آپ
      : await window.ethereum.request({ method: 'eth_requestAccounts' });  // با پاپ‌آپ
    if (!accs || !accs.length) return;

    currentAccount = accs[0];
    walletConnected = true;
    localStorage.setItem('res_wallet_connected', '1');

    web3 = new Web3(window.ethereum);
    res = new web3.eth.Contract(ABI, CONTRACT);
    council = null; // دوباره روی provider کیف پول ساخته میشود

    window.ethereum.on('accountsChanged', a => {
      currentAccount = a && a[0];
      updateWbtn();
      refresh();
    });
    window.ethereum.on('chainChanged', () => location.reload());

    // UI: دکمه اتصال → دکمه آدرس + منو
    $id('btn_connect').style.display = 'none';
    $id('wbtn').style.display = '';
    updateWbtn();

    const chainId = Number(await web3.eth.getChainId());
    if (chainId !== Number(CHAIN_ID_DEC)) return wrongChain();

    bind();
    await refresh();
  } catch (e) { console.error(e); alert('اتصال ناموفق: ' + (e.message || e)); }
}

function updateWbtn() {
  const a = currentAccount;
  $id('wbtn').textContent = `${a.slice(0, 6)}…${a.slice(-4)}`;
}
function wrongChain() {
  const wb = $id('wbtn');
  wb.textContent = '⚠ شبکه اشتباه — سوییچ کن';
  wb.onclick = () => window.ethereum.request({
    method: 'wallet_addEthereumChain',
    params: [{ chainId: '0x' + Number(CHAIN_ID_DEC).toString(16),
               chainName: CHAIN_NAME, rpcUrls: [RPC_URL],
               nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 } }],
  }).catch(() => {});
}

function send(method, ...args) {
  return method(...args).send({ from: currentAccount, gas: 1_000_000 });
}

// ── لایه ۱ چک دسترسی: قبل از ارسال تراکنش در UI ──
function guardOracle(action) {
  if (!myCountry || !myCountryActive) {
    alert(`⛔ فقط اوراکل فعال یک کشور مجاز به «${action}» است.`);
    return false;
  }
  return true;
}

// مرجع پرونده ثبتی = keccak256(abi.encode(کشور، شماره پرونده، salt)) — همان قالب تست‌ها
function caseRefPreview() {
  const no = $id('case_no').value.trim();
  if (!no || !myCountry) return null;
  return web3.utils.keccak256(web3.eth.abi.encodeParameters(['uint16', 'string', 'string'],
    [myCountry, no, $id('case_salt').value.trim()]));
}
function caseRef() {
  const h = caseRefPreview();
  if (!h) throw new Error('شماره پرونده ثبتی را وارد کنید (بالای پنل اوراکل)');
  return h;
}
function guardOwner(assetId, action) {
  if (!myAssets.includes(Number(assetId))) {
    alert(`⛔ شما مالک ملک #${assetId} نیستید — «${action}» ممکن نیست.`);
    return false;
  }
  return true;
}

async function tx(btn, fn) {
  btn.disabled = true;
  try { await fn(); }
  catch (e) { alert('خطا: ' + (e.message || e).toString().slice(0, 300)); }
  btn.disabled = false;
  refresh();
}

function bind() {
  // ---------- اوراکل ----------
  $id('add_to_eligible').onclick = () => { if (guardOracle('افزودن ولت مجاز'))
    tx($id('add_to_eligible'), () => send(res.methods.addToEligibleList, $id('add_eligible').value.trim(), caseRef())); };
  $id('remove_from_eligible').onclick = () => { if (guardOracle('انجماد سراسری'))
    tx($id('remove_from_eligible'), () => send(res.methods.removeFromEligibleList, $id('remove_eligible').value.trim(), caseRef())); };
  $id('local_freeze_btn').onclick = () => { if (guardOracle('انجماد محلی'))
    tx($id('local_freeze_btn'), () => send(res.methods.freezeLocal, $id('local_freeze_addr').value.trim(),
      $id('local_freeze_state').value === 'true', caseRef())); };
  $id('add_asset').onclick = () => { if (guardOracle('ضرب ملک'))
    tx($id('add_asset'), () => send(res.methods.addAsset, toWei($id('asset_price').value), $id('asset_owner').value.trim(), caseRef())); };
  $id('change_renter').onclick = () => { if (guardOracle('تغییر مستأجر'))
    tx($id('change_renter'), () => send(res.methods.changeRenter, +$id('asset_renter_id').value, $id('asset_renter_address_to').value.trim(), caseRef())); };
  $id('reissue_btn').onclick = () => { if (guardOracle('بازتخصیص ملک'))
    tx($id('reissue_btn'), () => send(res.methods.reissueAsset, +$id('reissue_id').value, $id('reissue_to').value.trim(), caseRef())); };
  $id('check_eligiblety').onclick = async () => {
    const a = $id('eligible_address').value.trim();
    const [ok, reg] = await Promise.all([res.methods.isEligible(a).call(), res.methods.registrarOf(a).call()]);
    let msg = (ok ? 'مجاز است ✓' : 'مجاز نیست ✗') + '\nکشور احرازکننده: ' + countryName(Number(reg));
    if (myCountry && await res.methods.localFrozen(myCountry, a).call()) msg += '\n⛔ در حوزه کشور شما منجمد محلی است';
    alert(msg);
  };
  ['case_no', 'case_salt'].forEach(id => $id(id).oninput = () => { $id('case_ref_preview').textContent = caseRefPreview() || '—'; });

  // ---------- شورای کشورها (DAO) ----------
  $id('req_btn').onclick = () => tx($id('req_btn'), () =>
    send(res.methods.requestOracle, +$id('req_country').value, $id('req_guardian').value.trim() || ZERO));
  $id('prop_btn').onclick = () => tx($id('prop_btn'), async () => {
    const c = await getCouncil();
    if (!c) throw new Error('شورای کشورها هنوز مالک قرارداد نیست');
    const type = $id('prop_type').value, country = +$id('prop_country').value;
    const data = type === 'suspend' ? res.methods.suspend(country).encodeABI()
      : type === 'approve' ? res.methods.approveOracle(country, $id('prop_addr').value.trim()).encodeABI()
      : res.methods.unpause().encodeABI();
    return send(c.methods.propose, data);
  });
  $id('guard_btn').onclick = () => tx($id('guard_btn'), () => send(res.methods.suspendSelf, +$id('guard_country').value));

  // ---------- مالک (dropdown ها از دارایی‌های واقعی کاربر پر میشوند) ----------
  $id('set_for_sale').onclick = () => {
    const id = +$id('fs_asset_id').value;
    if ($id('fs_asset_id').options.length === 0) return alert('شما ملکی ندارید');
    tx($id('set_for_sale'), () => send(res.methods.setForSale, id, $id('fs_state').value === 'true'));
  };
  $id('change_price').onclick = () => {
    if ($id('fs_asset_id').options.length === 0) return alert('شما ملکی ندارید');
    const id = +$id('fs_asset_id').value; // همان ملک انتخابی بخش وضعیت فروش
    tx($id('change_price'), () => send(res.methods.changePrice, id, toWei($id('assess_value').value)));
  };
  $id('set_custom_price').onclick = () => {
    if ($id('cp_asset_id').options.length === 0) return alert('شما ملکی ندارید');
    tx($id('set_custom_price'), () =>
      send(res.methods.setCustomPrice, +$id('cp_asset_id').value, $id('cp_buyer').value.trim(), toWei($id('cp_price').value || '0')));
  };
  $id('split').onclick = () => {
    if ($id('asset_to_split').options.length === 0) return alert('شما ملکی ندارید');
    tx($id('split'), () => send(res.methods.split, +$id('asset_to_split').value,
      [+$id('first_asset_percentage').value, +$id('second_asset_percentage').value],
      [$id('first_asset_address').value.trim(), $id('second_asset_address').value.trim()]));
  };
  $id('merge').onclick = () => {
    const id = +$id('merge_asset_id').value;
    tx($id('merge'), () => send(res.methods.merge, id));
  };
  $id('transfer_direct').onclick = () => {
    if ($id('td_asset_id').options.length === 0) return alert('شما ملکی ندارید');
    if (!confirm('انتقال بدون دریافت پرداخت انجام شود؟')) return;
    tx($id('transfer_direct'), () => send(res.methods.transferDirect, +$id('td_asset_id').value, $id('td_to').value.trim()));
  };

  // ---------- خریدار ----------
  // Buy: قیمت را خود قرارداد تعیین میکند (اختصاصی یا عمومی)
  $id('transfer_asset').onclick = () => tx($id('transfer_asset'), async () => {
    const id = +$id('transfer_asset_id').value;
    let price = await res.methods.customPrice(id, currentAccount).call();
    if (price == 0n || price == '0') price = (await res.methods.assets(id).call())[0];
    const input = $id('buy_value').value.trim();
    if (input && toWei(input) != price.toString())
      throw new Error(`مبلغ باید دقیقاً ${fromWei(price)} ETH باشد`);
    await res.methods.buy(id).send({ from: currentAccount, value: price.toString(), gas: 500_000 });
  });

  $id('take_asset_renter').onclick = async () => {
    try { alert('renter: ' + await res.methods.renterOf(+$id('asset_renter').value).call()); }
    catch { alert('renter ندارد'); }
  };

  document.querySelectorAll('#tabs button').forEach(t => t.onclick = () => showPane(t.dataset.pane));
}

function showPane(name) {
  document.querySelectorAll('#tabs button').forEach(b => b.classList.toggle('active', b.dataset.pane === name));
  document.querySelectorAll('.pane').forEach(p => p.classList.toggle('show', p.id === 'pane_' + name));
}

async function refresh() {
  try {
    $id('contract_addr').textContent = CONTRACT;
    const connected = walletConnected && !!currentAccount;

    // ── نقش‌ها و حذف کامل تب‌های بی‌دسترسی ──
    myAssets = [];
    const count = Number(await res.methods.assetCount().call());
    let ownedHtml = '', totalHtml = '';
    for (let i = 0; i < count; i++) {
      let r;
      try { r = await res.methods.getAsset(i).call(); } catch { continue; }
      // getAsset: (price, forSale, parent, percent, splitFlag, owner, renter) — named یا آرایه‌ای
      const price = Number(r.price ?? r[0]);
      const forSale = r.forSale ?? r[1];
      const parent = Number(r.parent ?? r[2]);
      const percent = Number(r.percent ?? r[3]);
      const owner = (r.owner ?? r[5]).toLowerCase();
      const renter = (r.renter ?? r[6]);
      const rentStart = Number(r.rentStart ?? r[7]);
      const rentExpiry = Number(r.rentExpiry ?? r[8]);
      const geo = Number(await res.methods.jurisdictionOf(i).call());
      const mine = connected && owner === currentAccount.toLowerCase();
      if (mine) myAssets.push(i);

      const isChild = parent !== 0;
      const tag = isChild
        ? `<span class="tag child">سهم ${percent}٪ از #${parent}</span>`
        : (forSale ? '<span class="tag sale">🟢 برای فروش</span>' : '<span class="tag nosale">🔴 خارج از فروش</span>');
      // مستأجر را فقط وقتی با مالک فرق دارد نشان بده (شلوغی نکند)
      const renterLine = renter && renter !== '0x0000000000000000000000000000000000000000'
        && renter.toLowerCase() !== owner
        ? `<div class="ownr mono" style="color:#1971c2">Renter: ${renter}</div>` : '';
      // اجاره فقط با دوره معتبر نمایش داده میشود (شروع/انقضا — طبق تصمیم on-chain حداقلی)
      const rentPeriodLine = rentStart && rentExpiry && rentStart !== 0 && rentExpiry !== 0
        ? `<div class="ownr" style="color:#1971c2">📅 اجاره: ${new Date(rentStart * 1000).toLocaleDateString('fa-IR')} → ${new Date(rentExpiry * 1000).toLocaleDateString('fa-IR')}</div>` : '';
      const card = `<div class="card${mine ? ' mine' : ''}">
        <div class="top"><span class="id">#${i}</span><span class="tag geo">🌐 ${countryName(geo)}</span>${tag}</div>
        <div class="price${price === 0 ? ' zero' : ''}">${price === 0 ? 'قیمت گذاشته نشده' : fromWei(price) + ' ETH'}</div>
        <div class="ownr mono">Owner: ${owner}</div>${renterLine}${rentPeriodLine}</div>`;
      totalHtml += card;
      if (mine) ownedHtml += card;
    }
    $id('assets').innerHTML = ownedHtml || `<div class="empty">${connected ? 'با این حساب چیزی ندارید' : 'برای مشاهده دارایی‌ها کیف پول را وصل کنید'}</div>`;
    $id('assets_total').innerHTML = totalHtml || '<div class="empty">خالی</div>';

    // نقش فعلی: اوراکل کشور → تب اوراکل + شورا؛ غیر اوراکل → مالک (اگر ملک دارد) + خریدار + شورا (درخواست/محافظ)
    myCountry = connected ? Number(await res.methods.countryOf(currentAccount).call()) : 0;
    myCountryActive = !!myCountry && !(await res.methods.suspended(myCountry).call());
    const isOracle = !!myCountry;
    const tabs = $id('tabs');
    tabs.querySelector('[data-pane=oracle]').style.display = isOracle ? '' : 'none';
    tabs.querySelector('[data-pane=owner]').style.display = (!isOracle && connected && myAssets.length) ? '' : 'none';
    tabs.querySelector('[data-pane=buyer]').style.display = (!isOracle && connected) ? '' : 'none';
    tabs.querySelector('[data-pane=dao]').style.display = connected ? '' : 'none';
    $id('role_badge').textContent = !connected ? 'ولت متصل نیست'
      : isOracle ? `نقش شما: اوراکل ${countryName(myCountry)}${myCountryActive ? '' : ' — ⛔ تعلیق'}`
      : (myAssets.length ? 'نقش شما: مالک / خریدار' : 'نقش شما: خریدار');
    $id('my_country').textContent = myCountry ? countryName(myCountry) : '—';
    $id('case_ref_preview').textContent = caseRefPreview() || '—';

    // پنل فعال را روی اولین تبِ موجود بگذار
    const visible = [...tabs.querySelectorAll('button')].filter(b => b.style.display !== 'none');
    if (visible.length && !visible.some(b => b.classList.contains('active'))) visible[0].click();

    // dropdown ملک‌های من در فرم‌های مالک
    fillAssetSelects();

    await renderDevWallets();
    await renderDao();
  } catch (e) { console.error(e); document.body.insertAdjacentHTML('beforeend',
    `<pre style="color:red;padding:10px">${(e.stack || e.message).toString().slice(0, 500)}</pre>`); }
}

function fillAssetSelects() {
  ['fs_asset_id', 'cp_asset_id', 'td_asset_id', 'asset_to_split'].forEach(id => {
    const sel = $id(id);
    const prev = sel.value;
    sel.innerHTML = '';
    if (!myAssets.length) { sel.add(new Option('— ملکی ندارید —', '')); return; }
    myAssets.forEach(i => sel.add(new Option(`#${i}`, i)));
    if ([...sel.options].some(o => o.value == prev)) sel.value = prev;
  });
}

// getLogs در رنج‌های ۹تایی (Alchemy free tier سقف ۱۰ بلاک دارد)
async function getLogsChunked(eventName, from, to) {
  // web3 v4: رویدادهای گذشته با contract.getPastEvents(name) — events[name] فقط subscription است
  const out = [];
  for (let b = from; b <= to; b += 9) {
    const end = Math.min(b + 9, to);
    try {
      (await res.getPastEvents(eventName, { fromBlock: b, toBlock: end })).forEach(e => out.push(e));
    } catch (e) { console.warn('getLogs chunk', b, e.message); }
  }
  return out;
}

// لیست ولت‌های مجاز — از ایونت‌های قرارداد ساخته میشود (EligibleAdded/Removed)
// ponytail: کل تاریخچه ایونت هر بار scan میشود؛ اگر قرارداد خیلی بزرگ شد، از آخرین بلاک ذخیره‌شده ادامه بده
async function renderDevWallets() {
  const box = $id('dev_wallets');
  if (!box) return;

  const eligible = new Map(); // addr -> آخرین وضعیت true/false
  // Alchemy free tier: eth_getLogs حداکثر رنج ۱۰ بلاک — پس از بلاک دیپلوی chunk-chunk میخوانیم
  const DEPLOY_BLOCK = Q.get('deployBlock') ? Number(Q.get('deployBlock'))
    : CHAIN_ID_DEC === '31337' ? 0 : 11578403; // ponytail: هاردکد Sepolia؛ برای شبکه دیگر پارامتر deployBlock بده
  const latest = Number(await web3.eth.getBlockNumber());
  const [added, removed] = await Promise.all([
    getLogsChunked('EligibleAdded', DEPLOY_BLOCK, latest),
    getLogsChunked('EligibleRemoved', DEPLOY_BLOCK, latest),
  ]);
  added.forEach(e => eligible.set(e.returnValues.account.toLowerCase(), true));
  removed.forEach(e => eligible.set(e.returnValues.account.toLowerCase(), false));
  for (const [a, ok] of [...eligible]) if (!ok) eligible.delete(a);

  let known = {};
  try { (await web3.eth.getAccounts()).forEach(a => known[a.toLowerCase()] = true); } catch {}

  let html = '';
  for (const a of [...eligible.keys()].sort()) {
    let bal = '';
    if (known[a]) bal = `<span class="bal mono">${(+fromWei(await web3.eth.getBalance(a))).toFixed(1)} ETH</span>`;
    const me = !!currentAccount && a === currentAccount.toLowerCase();
    html += `<div class="wchip">
      <span class="addr mono ${me ? 'me' : ''}">${a}${me ? ' ← فعلی' : ''}</span>
      <span style="display:flex;gap:10px;align-items:center"><span class="ok">مجاز ✓</span>${bal}</span></div>`;
  }
  box.innerHTML = html || '<div class="empty">هنوز ولتی مجاز نشده</div>';
}

// ── شورای کشورها ──
// مالک قرارداد اگر قرارداد باشد و proposalCount داشته باشد = OracleCouncil؛ وگرنه هنوز ولت دیپلویر است
async function getCouncil() {
  if (council) return council;
  const owner = await res.methods.owner().call();
  if ((await web3.eth.getCode(owner)) === '0x') return null;
  const c = new web3.eth.Contract(COUNCIL_ABI, owner);
  try { await c.methods.proposalCount().call(); } catch { return null; }
  return (council = c);
}

// متن خوانای یک پیشنهاد از calldata
function describe(data) {
  const sel = data.slice(0, 10), args = '0x' + data.slice(10);
  const is = (m) => sel === web3.eth.abi.encodeFunctionSignature(m);
  try {
    if (is('suspend(uint16)')) return `تعلیق اوراکل ${countryName(Number(web3.eth.abi.decodeParameter('uint16', args)))}`;
    if (is('approveOracle(uint16,address)')) {
      const d = web3.eth.abi.decodeParameters(['uint16', 'address'], args);
      return `تأیید ${d[1]} برای ${countryName(Number(d[0]))}`;
    }
    if (is('unpause()')) return 'ازسرگیری بازار';
    if (is('upgradeToAndCall(address,bytes)')) return 'ارتقای قرارداد';
  } catch {}
  return 'فراخوانی ' + sel;
}

async function renderDao() {
  const owner = await res.methods.owner().call();
  const c = await getCouncil();
  $id('dao_owner').textContent = owner + (c ? ' (OracleCouncil)' : ' — ⚠ هنوز ولت دیپلویر؛ شورا مستقر نشده');

  const countries = (await res.methods.countries().call()).map(Number);
  let rows = '';
  for (const k of countries) {
    const [o, susp, g] = await Promise.all([res.methods.oracleOf(k).call(), res.methods.suspended(k).call(), res.methods.guardianOf(k).call()]);
    rows += `<tr><td>${countryName(k)}</td><td class="mono">${o}</td>
      <td>${susp ? '<span class="tag bad">تعلیق</span>' : '<span class="ok">فعال ✓</span>'}</td>
      <td class="mono">${g === ZERO ? '—' : g}</td></tr>`;
  }
  $id('dao_countries').innerHTML = `<table class="dao"><tr><th>کشور</th><th>اوراکل</th><th>وضعیت</th><th>کلید محافظ</th></tr>${rows}</table>`;

  if (!c) { $id('dao_proposals').innerHTML = '<div class="empty">شورا هنوز مستقر نشده</div>'; return; }
  const n = Number(await c.methods.proposalCount().call());
  const now = Date.now() / 1000;
  let prows = '';
  for (let id = n - 1; id >= 0; id--) {
    const p = await c.methods.proposal(id).call();
    const t = await c.methods.tally(id).call();
    const votes = Number(t.votes ?? t[0]), eligible = Number(t.eligible ?? t[1]);
    const executed = p.executed ?? p[3], deadline = Number(p.deadline ?? p[2]);
    const voters = (p.voters ?? p[4]).map(Number);
    const status = executed ? '<span class="ok">اجرا شد ✓</span>' : deadline < now ? '<span class="tag nosale">منقضی</span>'
      : `${votes} از ${eligible} (لازم: ${Math.ceil(eligible * 2 / 3)})`;
    const canVote = !executed && deadline >= now && myCountryActive && !voters.includes(myCountry);
    prows += `<tr><td>#${id}</td><td>${describe(p.data ?? p[0])}</td><td>${voters.map(countryName).join('، ')}</td><td>${status}</td>
      <td><button class="mini" data-vote="${id}" ${canVote ? '' : 'disabled'}>رأی موافق</button></td></tr>`;
  }
  $id('dao_proposals').innerHTML = prows
    ? `<table class="dao"><tr><th>#</th><th>تصمیم</th><th>رأی‌دهندگان</th><th>وضعیت</th><th></th></tr>${prows}</table>`
    : '<div class="empty">پیشنهادی ثبت نشده</div>';
  $id('dao_proposals').querySelectorAll('[data-vote]').forEach(b =>
    b.onclick = () => tx(b, () => send(c.methods.vote, +b.dataset.vote)));
}

window.addEventListener('load', init().catch(e => alert('اتصال برقرار نشد: ' + e.message)));
