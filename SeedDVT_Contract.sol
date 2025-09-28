// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract SeedDVT is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdt;
    address public vault;
    uint256 public constant MAX_SUPPLY = 2_480_000 * 1e18;

    uint256 public constant TIME_FACTOR = 1;
    uint256 public constant SECONDS_IN_MONTH =
        (30 * 24 * 60 * 60) / TIME_FACTOR;
    uint256 public constant LOCK_DURATION = 36 * SECONDS_IN_MONTH;
    uint256 public constant REWARD_START_DELAY = 12 * SECONDS_IN_MONTH;
    uint256 public constant REWARD_INTERVAL = SECONDS_IN_MONTH;

    uint256 public constant REWARD_PERCENT_PER_MONTH = 100;
    uint256 public constant BASIS_POINT = 10000;
    uint256 public constant MAX_MONTHS = 24;
    uint8 private constant USDT_DECIMALS = 6;

    bool public isSeedSaleActive = true;

    struct Investment {
        uint256 id;
        uint256 amount;
        uint256 startTime;
        uint256 claimedMonths;
        bool rewardFinished;
    }

    struct InvestmentView {
        uint256 id;
        uint256 amount;
        uint256 claimValue;
        uint256 unclaimValue;
        uint256 startTime;
        uint256 endTime;
        uint256 progress;
        uint256 claimedMonths;
        bool rewardFinished;
    }

    struct History {
        string detail;
        uint256 amount;
        string currency;
        uint256 date;
    }

    mapping(address => Investment[]) public userInvestments;
    mapping(address => uint256) public userInvestmentCount;
    mapping(address => History[]) private userHistory;

    event Bought(
        address indexed buyer,
        uint256 id,
        uint256 usdtAmount,
        uint256 sdtAmount,
        uint256 timestamp
    );
    event Claimed(address indexed user, uint256 reward, uint256 timestamp);
    event SeedSaleStatusUpdated(bool isActive);

    constructor(address _usdt, address _vault) ERC20("Seed DVT", "SeedDVT") {
        require(_usdt != address(0), "Invalid USDT address");
        require(_vault != address(0), "Invalid vault address");
        usdt = IERC20(_usdt);
        vault = _vault;
        _mint(address(this), MAX_SUPPLY);
    }

    function seedSale(uint256 usdtAmount) external nonReentrant {
        require(isSeedSaleActive, "SeedSale is not active");
        require(
            usdtAmount >= 100000 * 10 ** USDT_DECIMALS,
            "Minimum 100000 USDT"
        );

        usdt.safeTransferFrom(msg.sender, vault, usdtAmount);

        uint256 decimalDiff = decimals() - USDT_DECIMALS;
        uint256 sdtAmount = usdtAmount * (10 ** decimalDiff);

        uint256 currentId = userInvestmentCount[msg.sender]++;
        userInvestments[msg.sender].push(
            Investment(currentId, sdtAmount, block.timestamp, 0, false)
        );

        _transfer(address(this), msg.sender, sdtAmount);

        emit Bought(
            msg.sender,
            currentId,
            usdtAmount,
            sdtAmount,
            block.timestamp
        );

        userHistory[msg.sender].push(
            History({
                detail: "seed",
                amount: sdtAmount,
                currency: "USDT",
                date: block.timestamp
            })
        );
    }

    function ClaimReward(uint256 index) external nonReentrant {
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

        userHistory[msg.sender].push(
            History({
                detail: "claim",
                amount: reward,
                currency: "SeedDVT",
                date: block.timestamp
            })
        );
    }

    function _lockedBalance(
        address user
    ) internal view returns (uint256 locked) {
        Investment[] memory invs = userInvestments[user];
        for (uint256 i = 0; i < invs.length; i++) {
            if (block.timestamp < invs[i].startTime + LOCK_DURATION) {
                locked += invs[i].amount;
            }
        }
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        uint256 available = balanceOf(msg.sender) - _lockedBalance(msg.sender);
        require(amount <= available, "Amount exceeds unlocked balance");
        return super.transfer(to, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        uint256 available = balanceOf(from) - _lockedBalance(from);
        require(amount <= available, "Amount exceeds unlocked balance");
        return super.transferFrom(from, to, amount);
    }

    function remainingSupply() external view returns (uint256) {
        return balanceOf(address(this));
    }

    function _calculateInvestmentView(
        Investment memory inv
    ) internal pure returns (InvestmentView memory) {
        uint256 claimed = (inv.amount *
            REWARD_PERCENT_PER_MONTH *
            inv.claimedMonths) / BASIS_POINT;
        uint256 totalReward = (inv.amount *
            REWARD_PERCENT_PER_MONTH *
            MAX_MONTHS) / BASIS_POINT;
        uint256 unclaimed = totalReward > claimed ? totalReward - claimed : 0;
        uint256 endTime = inv.startTime + LOCK_DURATION;
        uint256 progress = (inv.claimedMonths * 10000) / MAX_MONTHS;

        return
            InvestmentView({
                id: inv.id,
                amount: inv.amount,
                claimValue: claimed,
                unclaimValue: unclaimed,
                startTime: inv.startTime,
                endTime: endTime,
                progress: progress,
                claimedMonths: inv.claimedMonths,
                rewardFinished: inv.rewardFinished
            });
    }

    function getUserInvestments(
        address user
    )
        external
        view
        returns (
            InvestmentView[] memory investments,
            uint256 totalInvestments,
            uint256 totalAmount,
            uint256 totalClaimed,
            uint256 totalLocked,
            uint256 totalUnlocked
        )
    {
        Investment[] memory invs = userInvestments[user];
        uint256 len = invs.length;
        investments = new InvestmentView[](len);

        totalInvestments = len;
        uint256 currentTime = block.timestamp;

        for (uint256 i = 0; i < len; ++i) {
            Investment memory inv = invs[i];

            investments[i] = _calculateInvestmentView(inv);

            totalAmount += inv.amount;
            totalClaimed += investments[i].claimValue;

            if (currentTime < investments[i].endTime) {
                totalLocked += inv.amount;
            } else {
                totalUnlocked += inv.amount;
            }
        }
    }

    function getUserHistory(
        address user
    ) external view returns (History[] memory) {
        return userHistory[user];
    }
}
