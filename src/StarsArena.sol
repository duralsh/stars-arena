// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

contract StarsArena is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    function initialize() public initializer {
        protocolFeeDestination = address(0x274Ac9f9D3720533e74432cDc6B2065f5A79A0AA);
        protocolFeeDestination2 = address(0x274Ac9f9D3720533e74432cDc6B2065f5A79A0AA);
        subjectFeePercent = 7 ether / 100;
        protocolFeePercent = 2 ether / 100;
        referralFeePercent = 1 ether / 100;
        initialPrice = 1 ether / 250;
        subscriptionDuration = 30 days;
        paused = 1;
        __Ownable_init();
        __ReentrancyGuard_init();
    }

    uint256 public subscriptionDuration;
    address public protocolFeeDestination;
    uint256 public protocolFeePercent;
    uint256 public subjectFeePercent;
    uint256 public referralFeePercent;
    uint256 public initialPrice;

    mapping(address => uint256) public weightA;
    mapping(address => uint256) public weightB;
    mapping(address => uint256) public weightC;
    mapping(address => uint256) public weightD;
    mapping(address => bool) private weightsInitialized;

    uint256 constant DEFAULT_WEIGHT_A = 80 ether / 100;
    uint256 constant DEFAULT_WEIGHT_B = 50 ether / 100;
    uint256 constant DEFAULT_WEIGHT_C = 2;
    uint256 constant DEFAULT_WEIGHT_D = 0;

    mapping(address => address) public userToReferrer;

    event Trade(address trader, address subject, bool isBuy, uint256 shareAmount, uint256 amount, uint256 protocolAmount, uint256 subjectAmount, uint256 referralAmount, uint256 supply, uint256 buyPrice, uint256 myShares);
    event ReferralSet(address user, address referrer);

    mapping(address => uint256) public revenueShare;
    mapping(address => uint256) public subscriptionPrice;
    mapping(address => bool) public subscriptionsEnabled;

    // SubscribersSubject => (Holder => Expiration)
    mapping(address => mapping(address => uint256)) public subscribers;

    mapping(address => address[]) public shareholders;

    // SharesSubject => (Holder => Balance)
    mapping(address => mapping(address => uint256)) public sharesBalance;

    // SharesSubject => Supply
    mapping(address => uint256) public sharesSupply;

    mapping(address => address) public subscriptionTokenAddress;
    mapping(address => bool) public allowedTokens;
    mapping(address => uint256) public pendingWithdrawals;
    mapping(address => mapping(address => uint256)) public pendingTokenWithdrawals;

    address public protocolFeeDestination2;
    uint256 public paused;
    mapping(address => uint256) tvl;

    receive() external payable {}

    function setPaused(bool _paused) external onlyOwner {
        if (_paused) {
            paused = 1;
        } else {
            paused = 0;
        }
    }

    function updateReferrer(address user, address referrer) external onlyOwner {
        userToReferrer[user] = referrer;
        emit ReferralSet(user, referrer);
    }

    function updateReferrers(address[] calldata users, address[] calldata referrers) external onlyOwner {
        require(users.length == referrers.length, "Invalid input");
        for (uint256 i = 0; i < users.length; i++) {
            userToReferrer[users[i]] = referrers[i];
            emit ReferralSet(users[i], referrers[i]);
        }
    }

    function setReferrer(address user, address referrer) internal {
        if (userToReferrer[user] == address(0) && user != referrer) {
            userToReferrer[user] = referrer;
            emit ReferralSet(user, referrer);
        }
    }

    function setReferralFeePercent(uint256 _feePercent) public onlyOwner {
        uint256 maxFeePercent = 2 ether / 100;
        require(_feePercent < maxFeePercent, "Invalid fee setting");
        referralFeePercent = _feePercent;
    }

    function setFeeDestination(address _feeDestination) external {
        require(msg.sender == protocolFeeDestination, "Unauthorized");
        protocolFeeDestination = _feeDestination;
    }

    function setFeeDestination2(address _feeDestination2) external {
        require(msg.sender == protocolFeeDestination2, "Unauthorized");
        protocolFeeDestination2 = _feeDestination2;
    }

    function setProtocolFeePercent(uint256 _feePercent) public onlyOwner {
        uint256 maxFeePercent = 4 ether / 100;
        require(_feePercent < maxFeePercent, "Invalid fee setting");
        protocolFeePercent = _feePercent;
    }

    function setSubjectFeePercent(uint256 _feePercent) public onlyOwner {
        uint256 maxFeePercent = 8 ether / 100;
        require(_feePercent < maxFeePercent, "Invalid fee setting");
        subjectFeePercent = _feePercent;
    }

    function getPrice(address subject, uint256 supply, uint256 amount) public view returns (uint256) {
        uint256 adjustedSupply = supply + DEFAULT_WEIGHT_C;
        if (adjustedSupply == 0) {
            return initialPrice;
        }
        uint256 sum1 = (adjustedSupply - 1) * (adjustedSupply) * (2 * (adjustedSupply - 1) + 1) / 6;
        uint256 sum2 = (adjustedSupply - 1 + amount) * (adjustedSupply + amount) * (2 * (adjustedSupply - 1 + amount) + 1) / 6;
        uint256 summation = DEFAULT_WEIGHT_A * (sum2 - sum1);
        uint256 price = DEFAULT_WEIGHT_B * summation * initialPrice / 1 ether / 1 ether;
        if (price < initialPrice) {
            return initialPrice;
        }
        return price;
    }

    function getMyShares(address sharesSubject) public view returns (uint256) {
        return sharesBalance[sharesSubject][msg.sender];
    }

    function getSharesSupply(address sharesSubject) public view returns (uint256) {
        return sharesSupply[sharesSubject];
    }

    function getBuyPrice(address sharesSubject, uint256 amount) public view returns (uint256) {
        return getPrice(sharesSubject, sharesSupply[sharesSubject], amount);
    }

    function getSellPrice(address sharesSubject, uint256 amount) public view returns (uint256) {
        if (sharesSupply[sharesSubject] == 0) {
            return 0;
        }
        if (amount == 0) {
            return 0;
        }
        if (sharesSupply[sharesSubject] < amount) {
            return 0;
        }
        return getPrice(sharesSubject, sharesSupply[sharesSubject] - amount, amount);
    }

    function getBuyPriceAfterFee(address sharesSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getBuyPrice(sharesSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;
        return price + protocolFee + subjectFee + referralFee;
    }

    function getSellPriceAfterFee(address sharesSubject, uint256 amount) public view returns (uint256) {
        uint256 price = getSellPrice(sharesSubject, amount);
        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;
        return price - protocolFee - subjectFee - referralFee;
    }

    function buySharesWithReferrer(address sharesSubject, uint256 amount, address referrer) public payable {
        if (referrer != address(0)) {
            setReferrer(msg.sender, referrer);
        }
        buyShares(sharesSubject, amount);
    }

    function sellSharesWithReferrer(address sharesSubject, uint256 amount, address referrer) public payable {
        if (referrer != address(0)) {
            setReferrer(msg.sender, referrer);
        }
        sellShares(sharesSubject, amount);
    }

    function buyShares(address sharesSubject, uint256 amount) public payable nonReentrant {
        require(paused == 0, "Contract is paused");
        require(amount > 0, "Amount must be greater than 0");
        uint256 supply = sharesSupply[sharesSubject];
        uint256 price = getPrice(sharesSubject, supply, amount);
        tvl[sharesSubject] += price;

        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;
        require(msg.value >= price + protocolFee + subjectFee + referralFee, "Insufficient payment");

        sharesBalance[sharesSubject][msg.sender] = sharesBalance[sharesSubject][msg.sender] + amount;
        sharesSupply[sharesSubject] = supply + amount;
        uint256 nextPrice = getBuyPrice(sharesSubject, 1);
        uint256 myShares = sharesBalance[sharesSubject][msg.sender];
        uint256 totalShares = supply + amount;

        sendToProtocol(protocolFee);
        sendToSubject(sharesSubject, subjectFee);

        uint256 refundAmount = msg.value - (price + protocolFee + subjectFee + referralFee);

        if (refundAmount > 0) {
            sendToSubject(msg.sender, refundAmount);
        }
        if (referralFee > 0) {
            sendToReferrer(msg.sender, referralFee);
        }
        emit Trade(msg.sender, sharesSubject, true, amount, price, protocolFee, subjectFee, referralFee, totalShares, nextPrice, myShares);
    }


    function sellShares(address sharesSubject, uint256 amount) public payable nonReentrant {
        require(paused == 0, "Contract is paused");
        require(amount > 0, "Amount must be greater than 0");
        uint256 supply = sharesSupply[sharesSubject];
        uint256 price = getPrice(sharesSubject, supply - amount, amount);
        tvl[sharesSubject] -= price;

        uint256 protocolFee = price * protocolFeePercent / 1 ether;
        uint256 subjectFee = price * subjectFeePercent / 1 ether;
        uint256 referralFee = price * referralFeePercent / 1 ether;
        require(sharesBalance[sharesSubject][msg.sender] >= amount, "Insufficient shares");
        sharesBalance[sharesSubject][msg.sender] = sharesBalance[sharesSubject][msg.sender] - amount;
        sharesSupply[sharesSubject] = supply - amount;
        uint256 nextPrice = getBuyPrice(sharesSubject, 1);
        uint256 myShares = sharesBalance[sharesSubject][msg.sender];
        uint256 totalShares = supply - amount;

        sendToSubject(msg.sender, price - protocolFee - subjectFee - referralFee);
        sendToProtocol(protocolFee);
        sendToSubject(sharesSubject, subjectFee);

        if (referralFee > 0) {
            sendToReferrer(msg.sender, referralFee);
        }
        emit Trade(msg.sender, sharesSubject, false, amount, price, protocolFee, subjectFee, referralFee, totalShares, nextPrice, myShares);
    }

    function sendToSubject(address sharesSubject, uint256 subjectFee) internal {
        (bool success,) = sharesSubject.call{value: subjectFee}("");
        require(success, "Unable to send funds");
    }

    function sendToProtocol(uint256 protocolFee) internal {
        (bool success,) = protocolFeeDestination.call{value: protocolFee}("");
        require(success, "Unable to send funds");
    }

    function sendToReferrer(address sender, uint256 referralFee) internal {
        address referrer = userToReferrer[sender];
        if (referrer != address(0) && referrer != sender) {
            (bool success,) = referrer.call{value: referralFee, gas: 30_000}("");
            if (!success) {
                sendToProtocol(referralFee);
            }
        } else {
            sendToProtocol(referralFee);
        }
    }

    function withdrawFunds() external onlyOwner {
        uint256 contractBalanceBefore = address(this).balance;
        require(contractBalanceBefore > 0, "Contract has no balance to withdraw");
        (bool success, ) = owner().call{value: contractBalanceBefore}("");
        require(success, "Failed to withdraw funds");
    }

    function migrateTickets(address _subject, address[] calldata _traders, uint256[] calldata _amounts) external onlyOwner {
        require(_traders.length == _amounts.length, "Wrong lengths");
        require(sharesSupply[_subject] == 0, "Can't initialize twice");
        uint256 totalSupply;
        for (uint256 i = 0; i < _traders.length; i++) {
            require(sharesBalance[_subject][_traders[i]] == 0, "Can't initialize twice");
            sharesBalance[_subject][_traders[i]] = _amounts[i];
            totalSupply += _amounts[i];
            emit Trade(_traders[i], _subject, true, _amounts[i], 0, 0, 0, 0, totalSupply, 0, _amounts[i]);
        }
        tvl[_subject] = getPrice(_subject, 0, totalSupply);
        sharesSupply[_subject] = totalSupply;
    }

    function migrateTicketsFixed(address _subject, address[] calldata _traders, uint256[] calldata _amounts) external onlyOwner {
        require(_traders.length == _amounts.length, "Wrong lengths");
        uint256 totalSupply = sharesSupply[_subject];
        for (uint256 i = 0; i < _traders.length; i++) {
            require(sharesBalance[_subject][_traders[i]] == 0, "Can't initialize twice");
            sharesBalance[_subject][_traders[i]] = _amounts[i];
            totalSupply += _amounts[i];
            emit Trade(_traders[i], _subject, true, _amounts[i], 0, 0, 0, 0, totalSupply, 0, _amounts[i]);
        }
        tvl[_subject] = getPrice(_subject, 0, totalSupply);
        sharesSupply[_subject] = totalSupply;
    }

     function migrateTicketsWithReset(address _subject, address[] calldata _traders, uint256[] calldata _amounts) external onlyOwner {
        require(_traders.length == _amounts.length, "Wrong lengths");
        uint256 totalSupply = sharesSupply[_subject];
        uint256 sb = 0;
        for (uint256 i = 0; i < _traders.length; i++) {
            sb = sharesBalance[_subject][_traders[i]];
            if (sb != 0) {
                totalSupply -= sb;
                emit Trade(_traders[i], _subject, false, sb, 0, 0, 0, 0, totalSupply, 0, sb);
            }

            if (_amounts[i] != 0) {
              totalSupply += _amounts[i];
              emit Trade(_traders[i], _subject, true, _amounts[i], 0, 0, 0, 0, totalSupply, 0, _amounts[i]);
            }

            sharesBalance[_subject][_traders[i]] = _amounts[i];
        }
        tvl[_subject] = getPrice(_subject, 0, totalSupply);
        sharesSupply[_subject] = totalSupply;
    }
}