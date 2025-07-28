// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// USDT : 0xbDeaD2A70Fe794D2f97b37EFDE497e68974a296d
// Valt : 0x1957Fe4B931cc31f350D5c99925d0e87C19EBE8c

contract SeedDT_v1 is ERC20, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdt;
    address public vault;

    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;
    uint256 public constant SECONDS_PER_MONTH = 30 days;

    uint256 public constant LOCK_DURATION = 36 * SECONDS_PER_MONTH; // 3 years
    uint256 public constant REWARD_START_DELAY = 12 * SECONDS_PER_MONTH; // 1 year lock
    uint256 public constant REWARD_INTERVAL = 1 * SECONDS_PER_MONTH; // 2 years linear unlock (permonths)
    uint256 public constant REWARD_PERCENT_PER_MONTH = 100;  // 1% (calculation yield 8%)
    uint256 public constant BASIS_POINT = 10000;
    uint256 public constant MAX_MONTHS = 12; 
    uint8 private constant USDT_DECIMALS = 6;

    struct Investment {
        uint256 id;
        uint256 amount;
        uint256 startTime;
        uint256 claimedMonths;
        bool rewardFinished;
    }

    mapping(address => Investment[]) public userInvestments;
    mapping(address => uint256) public userInvestmentCount;

    event Bought(
        address indexed buyer,
        uint256 id,
        uint256 usdtAmount,
        uint256 sdtAmount,
        uint256 timestamp
    );
    event Claimed(address indexed user, uint256 reward, uint256 timestamp);
    event VaultUpdated(address indexed newVault);

    constructor(address _usdt, address _vault)
        ERC20("Seed DT", "SDT")
        Ownable(msg.sender)
    {
        require(_usdt != address(0), "Invalid USDT address");
        require(_vault != address(0), "Invalid vault address");

        usdt = IERC20(_usdt);
        vault = _vault;

        _mint(address(this), MAX_SUPPLY);
    }

    function buy(uint256 usdtAmount) external {
        require(usdtAmount >= 100000 * 10**USDT_DECIMALS, "Minimum 100000 USDT");

        usdt.safeTransferFrom(msg.sender, vault, usdtAmount);

        uint256 decimalDiff = decimals() - USDT_DECIMALS;
        uint256 sdtAmount = usdtAmount * (10**decimalDiff);

        uint256 currentId = userInvestmentCount[msg.sender];
        userInvestmentCount[msg.sender]++;

        userInvestments[msg.sender].push(
            Investment({
                id: currentId,
                amount: sdtAmount,
                startTime: block.timestamp,
                claimedMonths: 0,
                rewardFinished: false
            })
        );

        _transfer(address(this), msg.sender, sdtAmount);
        emit Bought(
            msg.sender,
            currentId,
            usdtAmount,
            sdtAmount,
            block.timestamp
        );
    }

    function claimReward(uint256 index) external {
        require(index < userInvestments[msg.sender].length, "Invalid index");

        Investment storage inv = userInvestments[msg.sender][index];
        require(!inv.rewardFinished, "Reward completed");

        uint256 elapsed = block.timestamp - inv.startTime;
        require(elapsed >= REWARD_START_DELAY, "Too early");

        uint256 maxElapsed = REWARD_START_DELAY +
            (MAX_MONTHS * REWARD_INTERVAL);
        if (elapsed > maxElapsed) elapsed = maxElapsed;

        uint256 monthsPassed = (elapsed - REWARD_START_DELAY) / REWARD_INTERVAL;
        if (monthsPassed > MAX_MONTHS) monthsPassed = MAX_MONTHS;
        require(monthsPassed > inv.claimedMonths, "Nothing to claim");

        uint256 toClaim = monthsPassed - inv.claimedMonths;
        uint256 reward = (inv.amount * REWARD_PERCENT_PER_MONTH * toClaim) /
            BASIS_POINT;

        inv.claimedMonths += toClaim;
        if (inv.claimedMonths >= MAX_MONTHS) {
            inv.rewardFinished = true;
        }

        _transfer(address(this), msg.sender, reward);
        emit Claimed(msg.sender, reward, block.timestamp);
    }

    function _lockedBalance(address user)
        internal
        view
        returns (uint256 locked)
    {
        Investment[] memory invs = userInvestments[user];
        for (uint256 i = 0; i < invs.length; i++) {
            if (block.timestamp < invs[i].startTime + LOCK_DURATION) {
                locked += invs[i].amount;
            }
        }
    }

    function transfer(address to, uint256 amount)
        public
        override
        returns (bool)
    {
        uint256 locked = _lockedBalance(msg.sender);
        uint256 available = balanceOf(msg.sender) - locked;
        require(amount <= available, "Amount exceeds unlocked balance");
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        uint256 locked = _lockedBalance(from);
        uint256 available = balanceOf(from) - locked;
        require(amount <= available, "Amount exceeds unlocked balance");
        return super.transferFrom(from, to, amount);
    }

    function setVault(address newVault) external onlyOwner {
        require(newVault != address(0), "Vault cannot be zero");
        vault = newVault;
        emit VaultUpdated(newVault);
    }

    function getUserInvestments(address user)
        external
        view
        returns (Investment[] memory investments)
    {
        return userInvestments[user];
    }

    function getUserInvestmentSummary(address user)
        external
        view
        returns (
            uint256 totalUnlocked,
            uint256 totalLocked,
            uint256 totalCount
        )
    {
        Investment[] memory invs = userInvestments[user];
        totalCount = invs.length;
        for (uint256 i = 0; i < invs.length; i++) {
            if (block.timestamp >= invs[i].startTime + LOCK_DURATION) {
                totalUnlocked += invs[i].amount;
            } else {
                totalLocked += invs[i].amount;
            }
        }
    }

    function pendingReward(address user, uint256 index)
        external
        view
        returns (uint256 reward)
    {
        if (index >= userInvestments[user].length) return 0;

        Investment memory inv = userInvestments[user][index];
        if (inv.rewardFinished) return 0;

        uint256 elapsed = block.timestamp - inv.startTime;

        if (elapsed < REWARD_START_DELAY) return 0;

        uint256 maxElapsed = REWARD_START_DELAY +
            (MAX_MONTHS * REWARD_INTERVAL);
        if (elapsed > maxElapsed) elapsed = maxElapsed;

        uint256 monthsPassed = (elapsed - REWARD_START_DELAY) / REWARD_INTERVAL;
        if (monthsPassed > MAX_MONTHS) monthsPassed = MAX_MONTHS;
        if (monthsPassed <= inv.claimedMonths) return 0;

        uint256 toClaim = monthsPassed - inv.claimedMonths;
        reward =
            (inv.amount * REWARD_PERCENT_PER_MONTH * toClaim) /
            BASIS_POINT;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
