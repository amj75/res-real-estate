// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
// OZ v5: ReentrancyGuard دیگر upgradeable جدا ندارد — از namespaced storage (ERC-7201) استفاده میکند
// و با Initializable سازگار است؛ مستقیم از contracts/ وارد میشود
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title RESNFT — Real Estate NFT (نسخه بازنویسی‌شده پایان‌نامه) — UUPS upgradeable
 * منطق مدل پایان‌نامه: اوراکل = مرجع قانونی ثبت، NFT مالکیت + رنتر (حق استفاده)،
 * تقسیم توکن به فرزندان درصدی، ادغام فرزندان به والد.
 * v4: بازار بدون مرز با اوراکل فدرال — هر کشور (کد عددی ISO 3166) یک اوراکل دارد: مرجع ثبت همان
 * کشور با یک آدرس که در استقرار واقعی multisig (مثل Safe) امضاکنندگان مجاز آن نهاد است.
 * - هر ملک به حوزه قضایی کشور ضرب‌کننده تعلق دارد؛ فقط اوراکل همان کشور آن را مدیریت میکند
 * - هر ولت را کشوری احراز میکند (registrar)؛ خریدار هر کشور میتواند ملک هر کشور را بخرد
 * - انجماد به دستور مرجع قانونی: سراسری (کشور احرازکننده ولت) یا محلی (هر کشور برای ملک‌های خودش)
 * - مالک قرارداد = OracleCouncil (DAO کشورها): تعلیق فوری اوراکل لو رفته و عضویت/انتصاب با ۲/۳ اعضا؛
 *   آدرس جدید را خود کشور (با همان آدرس) درخواست میدهد، DAO خارج از زنجیره اصالت درخواست و سطح امنیت
 *   کیف پول را بررسی و با ۲/۳ تأیید میکند؛ کلید محافظ هر کشور میتواند اوراکل خودش را تعلیق کند
 * - هر اقدام اوراکل یک مرجع پرونده ثبتی (caseRef) الزامی دارد و رویداد OracleAction منتشر میکند؛
 *   هر کسی (کشورهای دیگر، مالکان، ناظرها) میتواند هر اقدام را با پرونده مرجع ثبت تطبیق دهد —
 *   اقدامی که پرونده ندارد نشانه لو رفتن کلید اوراکل است
 * و: توقف اضطراری، اتصال ولت به هویت با امضای خود ولت، پاک‌سازی وضعیت فروش در هر تغییر مالکیت،
 * ایندکس فرزندان برای merge.
 */
contract RESNFT is ERC721Upgradeable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    // ponytail: قیمت و درصد به واحد توکن native نگه داشته شدن — استیبل‌کوین بعداً اگر لازم شد
    uint256 public assetCount;
    address public oracleAddress; // اوراکل کشور پیش‌فرض (سازگاری با v3 و UI)؛ مرجع اصلی: oracleOf

    struct Asset {
        uint256 price;   // به wei؛ 0 = غیرقابل خرید
        bool    forSale; // مالک اجازه فروش داده؟
        uint256 parent;  // 0 = والد
        uint256 percent; // 100 = کامل، مجموع فرزندان = درصد والد
        bool    split;   // والدی که split شده (از اعتبار ساقط شده ولی رکوردش هست)
    }

    mapping(uint256 => Asset) public assets;
    mapping(uint256 => address) public renterOf;
    // v3: قیمت اختصاصی بدون دوره فروش — باگ: بعد از فروش باقی میماند. فقط برای حفظ layout نگه داشته شده
    mapping(uint256 => mapping(address => uint256)) private _legacyCustomPrice;
    // دوره اجاره: [تاریخ شروع، تاریخ انقضا] ثانیه یونیکسی — فقط برای نمایش؛ بقیه فرآیند اجاره آف‌چین است
    mapping(uint256 => uint64[2]) public rentPeriod;
    mapping(address => bool) private _eligible;

    // ---------- v4 — ⚠ فقط به انتهای لیست اضافه شود تا layout پروکسی v3 حفظ شود ----------
    // هر تغییر مالکیت دوره فروش را یکی جلو میبرد؛ تخفیف‌ها به دوره گره خورده‌اند پس با مالک قبلی باطل میشوند
    mapping(uint256 => uint256) public saleEpoch;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) private _customPrice;
    mapping(uint256 => uint256[]) private _children; // والد → فرزندان؛ merge بدون اسکن کل دارایی‌ها
    mapping(address => bytes32) public identityOf; // تعهد هش‌شده هویت (salt + کد ملی) — خود هویت آف‌چین نزد اوراکل
    mapping(address => uint256) public walletNonce; // ضد replay برای امضای ثبت ولت

    // ---------- فدراسیون اوراکل‌ها (کشور = کد عددی ISO 3166، صفر یعنی هیچ) ----------
    uint16 public defaultJurisdiction;                 // حوزه ملک‌ها/ولت‌های بدون برچسب (v3 و کشور اول)
    uint16[] private _countries;
    mapping(uint16 => address) public oracleOf;
    mapping(address => uint16) public countryOf;       // اوراکل فعلی → کشور
    mapping(uint16 => bool) public suspended;          // اوراکل تعلیق‌شده: نه اختیار، نه معامله در آن حوزه
    mapping(uint16 => address) public guardianOf;      // کلید محافظ: فقط میتواند اوراکل همان کشور را تعلیق کند
    // درخواست عضویت/تعویض: کشور → آدرس متقاضی → کلید محافظ پیشنهادی (+ وجود درخواست)
    mapping(uint16 => mapping(address => bool)) public oracleRequested;
    mapping(uint16 => mapping(address => address)) public requestedGuardian;
    mapping(uint256 => uint16) private _jurisdiction;  // ملک → کشور (صفر = defaultJurisdiction؛ صرفه‌جویی گس)
    mapping(address => uint16) private _registrar;     // ولت → کشور احرازکننده (صفر = defaultJurisdiction)
    mapping(uint16 => mapping(address => bool)) public localFrozen; // انجماد محلی: کشور → ولت

    event ForSaleSet(uint256 indexed assetId, bool forSale, uint256 price);
    event CustomPriceSet(uint256 indexed assetId, address indexed buyer, uint256 price);
    event Transferred(uint256 indexed assetId, address indexed from, address indexed to);
    event AssetMinted(uint256 indexed assetId, address indexed to, uint256 price);
    event PriceChanged(uint256 indexed assetId, uint256 newPrice);
    event RenterChanged(uint256 indexed assetId, address indexed newRenter);
    event AssetSplit(uint256 indexed parentId, uint256[] childrenIds, uint256[] percents);
    event AssetsMerged(uint256 indexed parentId);
    event EligibleAdded(address indexed account);
    event EligibleRemoved(address indexed account);
    event Sold(uint256 indexed assetId, address indexed seller, address indexed buyer, uint256 price);
    event AssetReissued(uint256 indexed assetId, address indexed from, address indexed to);
    event OracleChanged(uint16 indexed country, address previousOracle, address newOracle);
    event OracleRequested(uint16 indexed country, address indexed oracle, address guardian);
    event OracleSuspended(uint16 indexed country, address by);
    event LocalFreeze(uint16 indexed country, address indexed account, bool frozen);
    /// caseRef = keccak256(کد کشور، شماره پرونده ثبتی، salt) — شماره پرونده آشکار نمیشود؛ مرجع ثبت
    /// پیش‌تصویر را به ناظر مجاز (عضو DAO، مالک ملک) نشان میدهد. action = selector تابع اوراکل
    event OracleAction(uint16 indexed country, bytes32 indexed caseRef, bytes4 indexed action);
    event IdentityBound(address indexed wallet, bytes32 commitment);
    /// ERC-4907 (NFT اجاره‌ای): حق استفاده روی همان توکن مالکیت؛ expires = 0 یعنی بدون انقضا (مالک/بدون دوره)
    event UpdateUser(uint256 indexed tokenId, address indexed user, uint64 expires);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// استقرار تازه — مستقیم به نسخه ۲ مقداردهی (initializeV2 دیگر قابل فراخوانی نیست)
    /// country: کشور اول (فراخوان = اوراکل آن و مالک موقت تا انتقال مالکیت به OracleCouncil)
    function initialize(uint16 country) public reinitializer(2) {
        __ERC721_init("Real Estate NFT", "RESNFT");
        __Ownable_init(msg.sender);
        __Pausable_init();
        require(country != 0, "bad country");
        defaultJurisdiction = country;
        _setOracle(country, msg.sender);
    }

    /// مهاجرت پروکسی v3 موجود: اوراکل قبلی اوراکل کشور country میشود و همه ملک‌های قبلی در آن حوزه
    function initializeV2(uint16 country) public reinitializer(2) onlyOwner {
        __Pausable_init();
        require(country != 0, "bad country");
        defaultJurisdiction = country;
        _setOracle(country, oracleAddress);
    }

    /// کشورِ اوراکل فراخوان؛ اوراکل تعلیق‌شده هیچ اختیاری ندارد
    function _callerCountry() private view returns (uint16 c) {
        c = countryOf[msg.sender];
        require(c != 0 && !suspended[c], "only oracle");
    }

    /// اقدام اوراکل: کشور فراخوان + ثبت مرجع پرونده ثبتی (الزامی) روی زنجیره
    function _oracleAction(bytes32 caseRef) private returns (uint16 c) {
        c = _callerCountry();
        require(caseRef != bytes32(0), "case reference required");
        emit OracleAction(c, caseRef, msg.sig);
    }

    /// فقط اوراکل حوزه همین ملک
    function _requireJurisdiction(uint256 assetId, bytes32 caseRef) private {
        require(_oracleAction(caseRef) == jurisdictionOf(assetId), "wrong jurisdiction");
    }

    /// ارتقای قرارداد فقط توسط مالک
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ---------- گیت انتقال: مدل پایان‌نامه — توکن فقط بین ولت‌های مجاز جابجا میشود ----------
    /// نقطه واحد همه جابجایی‌ها (transferFrom/safeTransferFrom/buy/direct/split/merge/reissue)
    /// هر خروج توکن از یک ولت (انتقال یا burn) آگهی فروش، تخفیف‌ها و دوره اجاره را پاک میکند.
    function _update(address to, uint256 tokenId, address auth)
        internal override returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0)) {
            Asset storage a = assets[tokenId];
            a.forSale = false;
            delete a.price;              // مالک بعدی خودش قیمت میگذارد
            saleEpoch[tokenId]++;        // تخفیف‌های مالک قبلی باطل
            delete rentPeriod[tokenId];  // با مالکیت جدید، دوره اجاره قبلی بیاعتبار است
            if (to != address(0)) {
                _requireNotPaused();
                uint16 c = jurisdictionOf(tokenId);
                require(!suspended[c], "jurisdiction suspended"); // تا انتصاب اوراکل جدید
                require(canTrade(from, c), "sender not eligible"); // ولت منجمد به دستور مرجع قانونی
                _setUser(tokenId, to);   // حق استفاده به مالک جدید (دوره اجاره بالا پاک شد)
            }
        }
        if (to != address(0)) require(canTrade(to, jurisdictionOf(tokenId)), "receiver not eligible");
        return super._update(to, tokenId, auth);
    }

    // ---------- حاکمیت: مالک = OracleCouncil (DAO کشورها) ----------
    /// درخواست عضویت کشور جدید یا تعویض آدرس اوراکل (پس از هک/چرخش کلید) — فرستنده خود آدرس جدید است،
    /// پس کنترل آن روی زنجیره اثبات میشود. DAO خارج از زنجیره اصالت درخواست (از طرف همان مرجع ثبت؟)
    /// و سطح امنیت کیف پول (multisig، آستانه، نگهداری کلیدها) را بررسی میکند و سپس با approveOracle رأی میدهد.
    /// درخواست‌ها جدا نگه داشته میشوند: درخواست جعلی دیگران درخواست واقعی را از بین نمیبرد.
    function requestOracle(uint16 country, address guardian) external {
        require(country != 0, "bad country");
        require(countryOf[msg.sender] == 0 || countryOf[msg.sender] == country, "oracle of another country");
        oracleRequested[country][msg.sender] = true;
        requestedGuardian[country][msg.sender] = guardian;
        emit OracleRequested(country, msg.sender, guardian);
    }

    /// تأیید DAO (۲/۳): آدرس درخواست‌شده فوراً اوراکل کشور میشود و تعلیق برداشته میشود
    function approveOracle(uint16 country, address oracle) external onlyOwner {
        require(oracleRequested[country][oracle], "no such request");
        require(countryOf[oracle] == 0 || countryOf[oracle] == country, "oracle of another country");
        _setOracle(country, oracle);
        guardianOf[country] = requestedGuardian[country][oracle];
        delete oracleRequested[country][oracle];
        delete requestedGuardian[country][oracle];
    }

    /// تعلیق فوری اوراکل (رأی ۲/۳ DAO)
    function suspend(uint16 country) external onlyOwner {
        _suspend(country);
    }

    /// تعلیق اوراکل کشور توسط کلید محافظ خود آن کشور (کشف هک توسط خود مرجع)
    function suspendSelf(uint16 country) external {
        require(msg.sender == guardianOf[country] && msg.sender != address(0), "not guardian");
        _suspend(country);
    }

    /// توقف اضطراری کل بازار: هر اوراکل فعال یا مالک؛ ادامه فقط با مالک
    function pause() external {
        require(msg.sender == owner() || (countryOf[msg.sender] != 0 && !suspended[countryOf[msg.sender]]),
            "not authorized");
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function countries() external view returns (uint16[] memory) {
        return _countries;
    }

    function _setOracle(uint16 country, address oracle) private {
        address old = oracleOf[country];
        if (old == address(0)) _countries.push(country);
        else delete countryOf[old];
        oracleOf[country] = oracle;
        countryOf[oracle] = country;
        suspended[country] = false;
        if (country == defaultJurisdiction) oracleAddress = oracle;
        emit OracleChanged(country, old, oracle);
    }

    function _suspend(uint16 country) private {
        require(oracleOf[country] != address(0), "no such country");
        suspended[country] = true;
        emit OracleSuspended(country, msg.sender);
    }

    // ---------- اوراکل ----------
    /// ثبت ولت توسط کشور احرازکننده؛ ولتی که کشور دیگری احراز کرده فقط در اختیار همان کشور است
    function addToEligibleList(address account, bytes32 caseRef) external {
        _claim(account, _oracleAction(caseRef));
        _eligible[account] = true;
        emit EligibleAdded(account);
    }

    /// انجماد سراسری به دستور مرجع قانونی کشور احرازکننده: ولت در هیچ کشوری نه میگیرد نه میفرستد؛
    /// آزادسازی با برگرداندن به لیست، یا انتقال قانونی دارایی با reissueAsset توسط کشور هر ملک
    function removeFromEligibleList(address account, bytes32 caseRef) external {
        require(registrarOf(account) == _oracleAction(caseRef), "not registrar");
        _eligible[account] = false;
        emit EligibleRemoved(account);
    }

    /// انجماد محلی: کشور فقط معامله ملک‌های حوزه خودش را برای این ولت میبندد
    function freezeLocal(address account, bool frozen, bytes32 caseRef) external {
        uint16 c = _oracleAction(caseRef);
        localFrozen[c][account] = frozen;
        emit LocalFreeze(c, account, frozen);
    }

    function _claim(address account, uint16 c) private {
        if (_eligible[account] || _registrar[account] != 0) {
            require(registrarOf(account) == c, "registered by another country");
        }
        if (c != defaultJurisdiction) _registrar[account] = c;
    }

    /// ثبت ولت با اثبات کنترل: خود ولت پیام (قرارداد، زنجیره، ولت، تعهد هویت، nonce) را امضا کرده
    /// ERC-1271 هم پشتیبانی میشود (ولت قراردادی/multisig)
    function registerWallet(address wallet, bytes32 identityCommitment, bytes calldata signature, bytes32 caseRef)
        external
    {
        uint16 c = _oracleAction(caseRef);
        require(identityCommitment != bytes32(0), "empty identity");
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            walletBindingHash(wallet, identityCommitment)
        );
        require(SignatureChecker.isValidSignatureNow(wallet, digest, signature), "bad wallet signature");
        _claim(wallet, c);
        walletNonce[wallet]++;
        _eligible[wallet] = true;
        identityOf[wallet] = identityCommitment;
        emit EligibleAdded(wallet);
        emit IdentityBound(wallet, identityCommitment);
    }

    /// پیامی که ولت باید امضا کند (personal_sign)
    function walletBindingHash(address wallet, bytes32 identityCommitment) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, wallet, identityCommitment, walletNonce[wallet]));
    }

    /// در لیست مجاز و کشور احرازکننده‌اش معلق نیست (احراز اوراکل لو رفته تا انتصاب جدید معتبر نیست)
    function isEligible(address account) public view returns (bool) {
        return _eligible[account] && !suspended[registrarOf(account)];
    }

    /// مجاز به معامله ملک‌های حوزه country
    function canTrade(address account, uint16 country) public view returns (bool) {
        return isEligible(account) && !localFrozen[country][account];
    }

    function registrarOf(address account) public view returns (uint16) {
        uint16 c = _registrar[account];
        return c == 0 ? defaultJurisdiction : c;
    }

    function jurisdictionOf(uint256 assetId) public view returns (uint16) {
        uint16 c = _jurisdiction[assetId];
        return c == 0 ? defaultJurisdiction : c;
    }

    /// ضرب ملک جدید پس از صحت‌سنجی سند توسط مرجع ثبت؛ ملک در حوزه همان کشور
    function addAsset(uint256 price, address to, bytes32 caseRef) external nonReentrant returns (uint256 id) {
        uint16 c = _oracleAction(caseRef);
        require(canTrade(to, c), "owner not eligible");
        require(price > 0, "price must be > 0");
        id = assetCount++;
        if (c != defaultJurisdiction) _jurisdiction[id] = c;
        assets[id] = Asset(price, false, 0, 100, false);
        _setUser(id, to);
        _safeMint(to, id);
        emit AssetMinted(id, to, price);
    }

    /// ساقط کردن توکن سرقت‌شده/منجمد و ضرب مجدد برای مالک مشروع (بازیابی ولت، اجرای حکم)
    /// سهم (parent/percent) حفظ میشود تا مجموع مالکیت هرگز از ۱۰۰٪ بیشتر نشود
    function reissueAsset(uint256 assetId, address to, bytes32 caseRef) external nonReentrant {
        address from = _ownerOf(assetId);
        require(from != address(0), "no asset");
        _requireJurisdiction(assetId, caseRef);
        require(canTrade(to, jurisdictionOf(assetId)), "owner not eligible");
        _burn(assetId);          // _update: فروش/تخفیف/اجاره پاک
        _setUser(assetId, to);
        _safeMint(to, assetId);
        emit AssetReissued(assetId, from, to);
    }

    // ---------- مالک ----------
    /// تعیین وضعیت فروش: مالک تصمیم میگیرد اصلاً بفروشد یا نه
    function setForSale(uint256 assetId, bool forSale) external whenNotPaused {
        require(ownerOf(assetId) == msg.sender, "not owner");
        require(!forSale || assets[assetId].price > 0, "set price first");
        assets[assetId].forSale = forSale;
        emit ForSaleSet(assetId, forSale, assets[assetId].price);
    }

    function changePrice(uint256 assetId, uint256 newPrice) external {
        require(ownerOf(assetId) == msg.sender, "not owner");
        require(newPrice > 0, "price must be > 0");
        assets[assetId].price = newPrice;
        emit PriceChanged(assetId, newPrice);
    }

    /// قیمت اختصاصی برای یک خریدار خاص (تخفیف) — 0 = حذف. فقط در دوره فروش مالک فعلی معتبر است
    function setCustomPrice(uint256 assetId, address buyer, uint256 price) external {
        require(ownerOf(assetId) == msg.sender, "not owner");
        require(canTrade(buyer, jurisdictionOf(assetId)), "buyer not eligible");
        require(price == 0 || price < assets[assetId].price, "custom must be discount or 0");
        _customPrice[assetId][saleEpoch[assetId]][buyer] = price;
        emit CustomPriceSet(assetId, buyer, price);
    }

    function customPrice(uint256 assetId, address buyer) public view returns (uint256) {
        return _customPrice[assetId][saleEpoch[assetId]][buyer];
    }

    /// قیمتی که این خریدار باید بپردازد: تخفیف فقط اگر هنوز زیر قیمت عمومی باشد
    function priceFor(uint256 assetId, address buyer) public view returns (uint256 price) {
        price = assets[assetId].price;
        uint256 c = customPrice(assetId, buyer);
        if (c != 0 && c < price) price = c;
    }

    /// انتقال مستقیم به ولت واجد شرایط بدون پرداخت — برای ثبت معاملات خارج از زنجیره
    function transferDirect(uint256 assetId, address to) external nonReentrant {
        require(ownerOf(assetId) == msg.sender, "not owner");
        _transfer(msg.sender, to, assetId); // گیت eligible و پاک‌سازی در _update
        emit Transferred(assetId, msg.sender, to);
    }

    /// تغییر حق استفاده — فقط اوراکل حوزه ملک (طبق مدل پایان‌نامه)
    function changeRenter(uint256 assetId, address newRenter, bytes32 caseRef) external {
        require(_exists(assetId), "no asset");
        _requireJurisdiction(assetId, caseRef);
        require(canTrade(newRenter, jurisdictionOf(assetId)), "renter not eligible");
        _setUser(assetId, newRenter);
        emit RenterChanged(assetId, newRenter);
    }

    /// ثبت/به‌روزرسانی دوره اجاره: فقط مستأجر + تاریخ شروع/انقضا آنچین — بقیه فرآیند آف‌چین
    /// renter=0 یعنی لغو اجاره (دوره هم صفر میشود)
    function setRent(uint256 assetId, address renter, uint64 start, uint64 expiry, bytes32 caseRef) external {
        require(_exists(assetId), "no asset");
        _requireJurisdiction(assetId, caseRef);
        if (renter == address(0)) {
            delete rentPeriod[assetId];
            _setUser(assetId, address(0));
        } else {
            require(canTrade(renter, jurisdictionOf(assetId)), "renter not eligible");
            require(expiry > start, "expiry must be after start");
            rentPeriod[assetId] = [start, expiry];
            _setUser(assetId, renter);
        }
        emit RenterChanged(assetId, renter);
    }

    /// تقسیم NFT به N قطعه درصدی — فقط مالک، فقط توکن کاملِ والدِ تقسیم‌نشده
    function split(uint256 assetId, uint256[] calldata percents, address[] calldata to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256[] memory childIds)
    {
        require(ownerOf(assetId) == msg.sender, "not owner");
        uint16 j = jurisdictionOf(assetId);
        require(!suspended[j], "jurisdiction suspended");
        require(canTrade(msg.sender, j), "sender not eligible"); // ولت منجمد نمیتواند با split دارایی را جابجا کند
        // ملک کامل = percent 100. (parent==0 کافی نیست: فرزندان ملک #0 هم parent=0 دارند)
        require(assets[assetId].percent == 100 && !assets[assetId].split, "already split / child");
        require(percents.length == to.length && percents.length >= 2, "bad input");
        require(percents.length <= 20, "too many shares"); // ponytail: سقف دلخواه؛ اگر بازار واقعی خواست بالا برود

        uint256 total;
        for (uint256 i = 0; i < percents.length; i++) {
            require(percents[i] > 0 && percents[i] < assets[assetId].percent, "bad percent");
            require(canTrade(to[i], j), "receiver not eligible");
            total += percents[i];
        }
        require(total == assets[assetId].percent, "percents must sum to parent");

        // پدر اول از اعتبار ساقط میشود (رکوردش برای merge باقی میماند)، بعد فرزندان ضرب میشوند
        assets[assetId].split = true;
        _burn(assetId);

        childIds = new uint256[](percents.length);
        for (uint256 i = 0; i < percents.length; i++) {
            uint256 cid = assetCount++;
            if (j != defaultJurisdiction) _jurisdiction[cid] = j; // سهم در حوزه والد
            assets[cid] = Asset(0, false, assetId, percents[i], false);
            _children[assetId].push(cid);
            childIds[i] = cid;
            _safeMint(to[i], cid);
        }
        emit AssetSplit(assetId, childIds, percents);
    }

    /// ادغام همه فرزندان یک والد → بازگشت والد (فقط وقتی تمام فرزندان نزد فراخوان باشد)
    /// O(k) با k ≤ 20 — مستقل از تعداد کل ملک‌ها
    function merge(uint256 parentId) external nonReentrant whenNotPaused {
        require(assets[parentId].split, "not split");
        uint16 j = jurisdictionOf(parentId);
        require(!suspended[j], "jurisdiction suspended");
        require(canTrade(msg.sender, j), "sender not eligible");
        uint256[] memory kids = _children[parentId];
        require(kids.length >= 2, "children missing");

        uint256 totalPercent;
        for (uint256 i = 0; i < kids.length; i++) {
            require(ownerOf(kids[i]) == msg.sender, "caller does not own all children");
            totalPercent += assets[kids[i]].percent;
        }
        require(totalPercent == assets[parentId].percent, "percents incomplete");

        for (uint256 i = 0; i < kids.length; i++) _burn(kids[i]);
        delete _children[parentId];
        assets[parentId].split = false;
        _setUser(parentId, msg.sender);
        _safeMint(msg.sender, parentId);
        emit AssetsMerged(parentId);
    }

    function childrenOf(uint256 parentId) external view returns (uint256[] memory) {
        return _children[parentId];
    }

    // ---------- خرید اتمیک ----------
    /// پرداخت و انتقال در یک تراکنش. مبلغ باید دقیقاً برابر قیمت باشد، پس تغییر قیمت توسط فروشنده
    /// پیش از تأیید تراکنش (front-running) خرید را revert میکند و خریدار هیچ‌وقت بیشتر نمیپردازد.
    function buy(uint256 assetId) external payable nonReentrant whenNotPaused {
        address seller = _ownerOf(assetId);
        require(seller != address(0), "no asset");
        require(seller != msg.sender, "own asset");
        require(canTrade(msg.sender, jurisdictionOf(assetId)), "buyer not eligible");
        require(assets[assetId].forSale, "not for sale");

        uint256 price = priceFor(assetId, msg.sender);
        require(price > 0 && msg.value == price, "wrong value");

        // effects: انتقال توکن بدون approve + پاک‌سازی وضعیت فروش (در _update)
        _transfer(seller, msg.sender, assetId);

        // interaction: پرداخت به فروشنده در آخر؛ شکست = revert کل تراکنش (بدون وضعیت نیمه‌کاره)
        (bool ok, ) = payable(seller).call{value: price}("");
        require(ok, "seller transfer failed");
        emit Sold(assetId, seller, msg.sender, price);
    }

    function _exists(uint256 assetId) internal view returns (bool) {
        return _ownerOf(assetId) != address(0);
    }

    /// تنها نقطه تغییر حق استفاده — رویداد ERC-4907 همیشه منتشر میشود
    function _setUser(uint256 assetId, address user) private {
        renterOf[assetId] = user;
        emit UpdateUser(assetId, user, rentPeriod[assetId][1]);
    }

    // ---------- ERC-4907 (فقط بخش خواندن): تعیین کاربر با setRent/changeRenter و فقط توسط اوراکل حوزه
    // انجام میشود، نه مالک — پس setUser استاندارد و interfaceId آن اعلام نمیشود ----------
    /// دارنده فعلی حق استفاده: پس از انقضای اجاره یا اگر کسی تعیین نشده، خود مالک
    function userOf(uint256 assetId) external view returns (address) {
        address u = renterOf[assetId];
        uint64 exp = rentPeriod[assetId][1];
        if (u == address(0) || (exp != 0 && block.timestamp >= exp)) return ownerOf(assetId);
        return u;
    }

    /// پایان دوره استفاده (ثانیه یونیکسی)؛ 0 = بدون انقضا
    function userExpires(uint256 assetId) external view returns (uint256) {
        return rentPeriod[assetId][1];
    }

    // ---------- نمایش ----------
    function getAsset(uint256 assetId)
        external view returns (uint256 price, bool forSale, uint256 parent, uint256 percent, bool splitFlag,
                               address owner, address renter, uint64 rentStart, uint64 rentExpiry)
    {
        require(_exists(assetId), "no asset");
        Asset memory a = assets[assetId];
        uint64[2] memory rp = rentPeriod[assetId];
        return (a.price, a.forSale, a.parent, a.percent, a.split, _ownerOf(assetId), renterOf[assetId], rp[0], rp[1]);
    }
}
