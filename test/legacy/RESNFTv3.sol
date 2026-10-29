// SPDX-License-Identifier: GPL-3.0
// نسخه v3 (دیپلوی‌شده روی Sepolia در 2026-08-27) — فقط برای تست ارتقا و مقایسه مقیاس‌پذیری؛ دست نزنید
pragma solidity ^0.8.24;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// OZ v5: ReentrancyGuard دیگر upgradeable جدا ندارد — نسخه base از storage slot خود قرارداد استفاده نمیکند
// و با Initializable سازگار است؛ مستقیم از contracts/ وارد میشود
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title RESNFT — Real Estate NFT (نسخه بازنویسی‌شده پایان‌نامه) — UUPS upgradeable
 * منطق مدل پایان‌نامه: اوراکل = مرجع قانونی ثبت، NFT مالکیت + رنتر (حق استفاده)،
 * تقسیم توکن به فرزندان درصدی، ادغام فرزندان به والد.
 * ارتقا فقط توسط مالک قرارداد (Ownable) از طریق authorizeUpgrade انجام میشود.
 */
contract RESNFTv3 is ERC721Upgradeable, OwnableUpgradeable, ReentrancyGuard, UUPSUpgradeable {
    // ponytail: قیمت و درصد به واحد توکن native نگه داشته شدن — استیبل‌کوین بعداً اگر لازم شد
    uint256 public assetCount;
    address public oracleAddress;

    struct Asset {
        uint256 price;   // به wei؛ 0 = غیرقابل خرید
        bool    forSale; // مالک اجازه فروش داده؟
        uint256 parent;  // 0 = والد
        uint256 percent; // 100 = کامل، مجموع فرزندان = درصد والد
        bool    split;   // والدی که split شده (از اعتبار ساقط شده ولی رکوردش هست)
    }

    mapping(uint256 => Asset) public assets;
    mapping(uint256 => address) public renterOf;
    // قیمت اختصاصی برای آدرس خاص (تخفیف) — فقط وقتی forSale است اعمال میشود
    mapping(uint256 => mapping(address => uint256)) public customPrice;
    // دوره اجاره: [تاریخ شروع، تاریخ انقضا] ثانیه یونیکسی — فقط برای نمایش؛ بقیه فرآیند اجاره آف‌چین است
    // ⚠ در انتهای declarations تعریف شده تا layout قبلی (v2) حفظ شود
    mapping(uint256 => uint64[2]) public rentPeriod;

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __ERC721_init("Real Estate NFT", "RESNFT");
        __Ownable_init(msg.sender);
        oracleAddress = msg.sender;
    }

    modifier onlyOracle() {
        require(msg.sender == oracleAddress, "only oracle");
        _;
    }

    /// ارتقای قرارداد فقط توسط مالک
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ---------- گیت انتقال: مدل پایان‌نامه — توکن فقط بین ولت‌های مجاز جابجا میشود ----------
    /// نقطه واحد همه جابجایی‌ها (transferFrom/safeTransferFrom/approve→transfer/buy/direct)
    /// mint (from=0) و burn (to=0) آزاد؛ بقیه: گیرنده باید واجد شرایط باشد.
    function _update(address to, uint256 tokenId, address auth)
        internal override returns (address)
    {
        address from = _ownerOf(tokenId);
        if (to != address(0) && from != address(0)) {
            require(_eligible[to], "receiver not eligible");
            delete rentPeriod[tokenId];   // با مالکیت جدید، دوره اجاره قبلی بیاعتبار است
        }
        return super._update(to, tokenId, auth);
    }

    // ---------- اوراکل ----------
    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "zero address");
        oracleAddress = newOracle;
    }

    function addToEligibleList(address account) external onlyOracle {
        _eligible[account] = true;
        emit EligibleAdded(account);
    }

    function removeFromEligibleList(address account) external onlyOracle {
        _eligible[account] = false;
        emit EligibleRemoved(account);
    }

    mapping(address => bool) private _eligible;

    function isEligible(address account) external view returns (bool) {
        return _eligible[account];
    }

    /// ضرب ملک جدید توسط اوراکل پس از صحت‌سنجی سند
    function addAsset(uint256 price, address to) external onlyOracle returns (uint256 id) {
        require(_eligible[to], "owner not eligible");
        require(price > 0, "price must be > 0");
        id = assetCount++;
        _safeMint(to, id);
        assets[id] = Asset(price, false, 0, 100, false);
        renterOf[id] = to;
        emit AssetMinted(id, to, price);
    }

    /// ساقط کردن توکن سرقت‌شده/معیوب و ضرب مجدد برای مالک مشروع (بخش امنیت پایان‌نامه)
    function reissueAsset(uint256 assetId, address to) external onlyOracle {
        require(_exists(assetId), "no asset");
        require(_eligible[to], "owner not eligible");
        _burn(assetId);
        _safeMint(to, assetId);
        // وضعیت فروش/قیمت/تخفیف قبلی کاملاً پاک — ملک بازتخصیص‌یافته تازه است
        delete assets[assetId].price;
        assets[assetId].forSale = false;
        assets[assetId].split = false;
        delete assets[assetId].parent; // بازگشت به وضعیت کامل
        assets[assetId].percent = 100;
        renterOf[assetId] = to;
        emit Transfer(address(0), to, assetId);
    }

    // ---------- مالک ----------
    /// تعیین وضعیت فروش: مالک تصمیم میگیرد اصلاً بفروشد یا نه
    function setForSale(uint256 assetId, bool forSale) external {
        require(ownerOf(assetId) == msg.sender, "not owner");
        assets[assetId].forSale = forSale;
        emit ForSaleSet(assetId, forSale, assets[assetId].price);
    }

    function changePrice(uint256 assetId, uint256 newPrice) external {
        require(ownerOf(assetId) == msg.sender, "not owner");
        require(newPrice > 0, "price must be > 0");
        assets[assetId].price = newPrice;
        emit PriceChanged(assetId, newPrice);
    }

    /// قیمت اختصاصی برای یک خریدار خاص (تخفیف) — 0 = حذف قیمت اختصاصی
    function setCustomPrice(uint256 assetId, address buyer, uint256 price) external {
        require(ownerOf(assetId) == msg.sender, "not owner");
        require(_eligible[buyer], "buyer not eligible");
        require(price == 0 || price < assets[assetId].price, "custom must be discount or 0");
        customPrice[assetId][buyer] = price;
        emit CustomPriceSet(assetId, buyer, price);
    }

    /// انتقال مستقیم به ولت واجد شرایط بدون پرداخت — برای ثبت معاملات خارج از زنجیره
    function transferDirect(uint256 assetId, address to) external nonReentrant {
        require(ownerOf(assetId) == msg.sender, "not owner");
        require(_eligible[to], "receiver not eligible");

        _transfer(msg.sender, to, assetId);
        delete assets[assetId].price;
        assets[assetId].forSale = false;
        delete customPrice[assetId][to];
        renterOf[assetId] = to;
        emit Transferred(assetId, msg.sender, to);
    }

    /// تغییر حق استفاده — فقط اوراکل (طبق مدل پایان‌نامه)
    function changeRenter(uint256 assetId, address newRenter) external onlyOracle {
        require(_exists(assetId), "no asset");
        require(_eligible[newRenter], "renter not eligible");
        renterOf[assetId] = newRenter;
        emit RenterChanged(assetId, newRenter);
    }

    /// ثبت/به‌روزرسانی دوره اجاره: فقط مستأجر + تاریخ شروع/انقضا آنچین — بقیه فرآیند آف‌چین
    /// renter=0 یعنی لغو اجاره (دوره هم صفر میشود)
    function setRent(uint256 assetId, address renter, uint64 start, uint64 expiry) external onlyOracle {
        require(_exists(assetId), "no asset");
        if (renter == address(0)) {
            delete renterOf[assetId];
            delete rentPeriod[assetId];
        } else {
            require(_eligible[renter], "renter not eligible");
            require(expiry > start, "expiry must be after start");
            renterOf[assetId] = renter;
            rentPeriod[assetId] = [start, expiry];
        }
        emit RenterChanged(assetId, renter);
    }

    /// تقسیم NFT به N قطعه درصدی — فقط مالک، فقط توکن کاملِ والدِ تقسیم‌نشده
    function split(uint256 assetId, uint256[] calldata percents, address[] calldata to)
        external
        returns (uint256[] memory childIds)
    {
        require(ownerOf(assetId) == msg.sender, "not owner");
        require(assets[assetId].parent == 0 && !assets[assetId].split, "already split / child");
        require(percents.length == to.length && percents.length >= 2, "bad input");
        require(percents.length <= 20, "too many shares"); // ponytail: سقف دلخواه؛ اگر بازار واقعی خواست بالا برود

        uint256 total;
        for (uint256 i = 0; i < percents.length; i++) {
            require(percents[i] > 0 && percents[i] < assets[assetId].percent, "bad percent");
            require(_eligible[to[i]], "receiver not eligible");
            total += percents[i];
        }
        require(total == assets[assetId].percent, "percents must sum to parent");

        childIds = new uint256[](percents.length);
        for (uint256 i = 0; i < percents.length; i++) {
            uint256 cid = assetCount++;
            _safeMint(to[i], cid);
            assets[cid] = Asset(0, false, assetId, percents[i], false);
            childIds[i] = cid;
            emit Transfer(address(0), to[i], cid);
        }
        // پدر از اعتبار ساقط میشود ولی رکوردش برای merge باقی میماند
        assets[assetId].split = true;
        delete assets[assetId].price;   // قیمت والد به فرزندان منتقل نمیشود
        assets[assetId].forSale = false;
        _burn(assetId);
        emit AssetSplit(assetId, childIds, percents);
    }

    /// ادغام همه فرزندان یک والد → بازگشت والد (فقط وقتی تمام فرزندان نزد فراخوان باشد)
    function merge(uint256 parentId) external {
        require(assets[parentId].split, "not split");
        uint256 expected = assets[parentId].percent;
        // ponytail: شمارش فرزندان با اسکن کل دارایی‌ها O(n) — کافی تا چند هزار ملک؛ ایندکس فرزند اگر بزرگ شد
        uint256 found;
        uint256 totalPercent;
        for (uint256 i = 0; i < assetCount; i++) {
            if (assets[i].parent == parentId && _exists(i)) {
                require(ownerOf(i) == msg.sender, "caller does not own all children");
                totalPercent += assets[i].percent;
                found++;
            }
        }
        require(found >= 2, "children missing");
        require(totalPercent == expected, "percents incomplete");

        for (uint256 i = 0; i < assetCount; i++) {
            if (assets[i].parent == parentId && _exists(i)) {
                delete customPrice[i][ownerOf(i)]; // پاک‌سازی قیمت اختصاصی یتیم
                _burn(i);
            }
        }
        _safeMint(msg.sender, parentId);
        assets[parentId].split = false;
        renterOf[parentId] = msg.sender;
        emit AssetsMerged(parentId);
    }

    // ---------- خرید اتمیک ----------
    function buy(uint256 assetId) external payable nonReentrant {
        Asset storage a = assets[assetId];
        address seller = _ownerOf(assetId);
        require(seller != address(0), "no asset");
        require(seller != msg.sender, "own asset");
        require(_eligible[msg.sender], "buyer not eligible");
        require(a.forSale, "not for sale");
        require(msg.value > 0, "no value");

        // قیمت اختصاصی اگر تعیین شده وگرنه قیمت عمومی
        uint256 price = customPrice[assetId][msg.sender];
        if (price == 0) price = a.price;
        require(msg.value == price, "wrong value");

        // انتقال توکن بدون approve — چون پرداخت همزمان انجام میشود (اتمیک)
        _transfer(seller, msg.sender, assetId);

        // پاکسازی وضعیت بعد از فروش
        delete a.price;                 // خریدار بعداً قیمت میگذارد
        a.forSale = false;
        delete customPrice[assetId][msg.sender];
        renterOf[assetId] = msg.sender; // حق استفاده به خریدار برمیگردد
        (bool ok, ) = payable(seller).call{value: price}("");
        require(ok, "seller transfer failed");
        emit Transfer(seller, msg.sender, assetId);
    }

    function _exists(uint256 assetId) internal view returns (bool) {
        return _ownerOf(assetId) != address(0);
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
