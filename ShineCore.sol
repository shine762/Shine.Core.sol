// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract ShineCore {
    struct Matrix {
        address currentReferrer;
        address[] referrals;
        uint256 reinvestCount;
        bool blocked;
    }

    struct User {
        uint256 id;
        address upline;
        uint256 partnersCount;
        uint256 joinDate;
        bool isRegistered;
        mapping(uint8 => mapping(uint8 => bool)) activeLevels;
        mapping(uint8 => mapping(uint8 => Matrix)) matrices;
    }

    IERC20 public usdtToken;
    IERC20 public shineToken;
    uint256 public lastUserId = 1;
    address public rootOwner;
    address public tradingVault;
    address public feeWallet;
    address public airdropWallet;
    address public charityWallet;

    mapping(address => User) public users;
    mapping(uint256 => address) public idToAddress;

    event Registration(address indexed user, address indexed upline, uint256 userId);
    event Upgrade(address indexed user, uint8 program, uint8 level);
    event NewUserPlace(address indexed user, address indexed referrer, uint8 program, uint8 level, uint8 place);
    event Reinvest(address indexed user, address indexed currentReferrer, address indexed caller, uint8 program, uint8 level);
    event Distribution(address indexed user, uint256 tradingAmt, uint256 ownerAmt, uint256 up1, uint256 up2, uint256 up3);
    event ProfitDistributed(address indexed user, uint256 userAmt, uint256 uplineAmt, uint256 ownerAmt, uint256 airdropAmt, uint256 charityAmt);

    constructor() {
        usdtToken = IERC20(0x8Db81B051c65A7a7D539e896BdA7e4D792461DCF);
        shineToken = IERC20(0xa0399e5D113525d2C435519050A5EFDeE93Cbd94);
        tradingVault = 0x204e8c521aCa3621DB585829667759433aBb70d3;
        rootOwner = 0x99b23c8039E98a119eaed74e4F3FE5d68fF1abbA;
        feeWallet = 0x99b23c8039E98a119eaed74e4F3FE5d68fF1abbA;
        airdropWallet = 0xE5afe2967d5B00e8DAe7aaf8b536F7b408622Ed7;
        charityWallet = 0xa748027Ac30F83794d227AcB315FD90361a8F536;

        User storage root = users[rootOwner];
        root.id = 1;
        root.upline = address(0);
        root.isRegistered = true;
        root.joinDate = block.timestamp;
        idToAddress[1] = rootOwner;

        for (uint8 p = 1; p <= 15; p++) {
            for (uint8 l = 0; l < 12; l++) {
                users[rootOwner].activeLevels[p][l] = true;
            }
        }
    }

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TF");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TFF");
    }

    function register(address _upline) external payable {
        require(!users[msg.sender].isRegistered, "Registered");
        require(_upline != msg.sender, "Self upline");
        if (_upline == address(0) || !users[_upline].isRegistered) {
            _upline = rootOwner;
        }

        uint256 cost = getLevelCost(1, 0);
        safeTransferFrom(usdtToken, msg.sender, address(this), cost);

        if (msg.value > 0 && feeWallet != address(0)) {
            (bool success, ) = feeWallet.call{value: msg.value}("");
            require(success, "BNB transfer failed");
        }

        lastUserId++;
        User storage u = users[msg.sender];
        u.id = lastUserId;
        u.upline = _upline;
        u.isRegistered = true;
        u.joinDate = block.timestamp;
        idToAddress[lastUserId] = msg.sender;

        users[_upline].partnersCount++;
        u.activeLevels[1][0] = true;

        emit Registration(msg.sender, _upline, lastUserId);

        distributeFunds(cost, msg.sender, 1, 0);
        updateMatrix(msg.sender, _upline, 1, 0);
        sendAirdropTokens(msg.sender, cost);
    }

    function buyLevel(uint8 _program, uint8 _level) external payable {
        require(_program >= 1 && _program <= 15, "Invalid program");
        require(_level < 12, "Invalid level");
        require(users[msg.sender].isRegistered, "Register first");
        require(!users[msg.sender].activeLevels[_program][_level], "Active");

        if (_level > 0) {
            require(users[msg.sender].activeLevels[_program][_level - 1], "Unlock previous");
        }

        uint256 cost = getLevelCost(_program, _level);
        require(usdtToken.transferFrom(msg.sender, address(this), cost), "USDT transfer failed");

        if (msg.value > 0) {
            (bool success, ) = feeWallet.call{value: msg.value}("");
            require(success, "BNB transfer failed");
        }

        users[msg.sender].activeLevels[_program][_level] = true;

        if (_level > 0 && users[msg.sender].matrices[_program][_level - 1].blocked) {
            users[msg.sender].matrices[_program][_level - 1].blocked = false;
        }

        emit Upgrade(msg.sender, _program, _level);

        distributeFunds(cost, msg.sender, _program, _level);
        address freeReferrer = findFreeReferrer(msg.sender, _program, _level);
        updateMatrix(msg.sender, freeReferrer, _program, _level);
        sendAirdropTokens(msg.sender, cost);
    }

    function updateMatrix(address _user, address _referrer, uint8 _program, uint8 _level) internal {
        users[_user].matrices[_program][_level].currentReferrer = _referrer;
        users[_referrer].matrices[_program][_level].referrals.push(_user);

        uint8 maxSpots = getMaxSpots(_program);
        uint8 place = uint8(users[_referrer].matrices[_program][_level].referrals.length);

        emit NewUserPlace(_user, _referrer, _program, _level, place);

        if (place >= maxSpots) {
            reinvest(_referrer, _program, _level);
        }
    }

    function reinvest(address _user, uint8 _program, uint8 _level) internal {
        delete users[_user].matrices[_program][_level].referrals;
        users[_user].matrices[_program][_level].reinvestCount++;

        if (_level < 11 && !users[_user].activeLevels[_program][_level + 1] && _user != rootOwner) {
            users[_user].matrices[_program][_level].blocked = true;
        }

        address uplineReferrer = users[_user].matrices[_program][_level].currentReferrer;
        if (uplineReferrer == address(0)) {
            uplineReferrer = findFreeReferrer(_user, _program, _level);
        }

        emit Reinvest(_user, uplineReferrer, msg.sender, _program, _level);

        if (_user != rootOwner && uplineReferrer != address(0)) {
            updateMatrix(_user, uplineReferrer, _program, _level);
        }
    }

    function findFreeReferrer(address _user, uint8 _program, uint8 _level) public view returns (address) {
        address upline = users[_user].upline;
        while (upline != address(0)) {
            if (users[upline].activeLevels[_program][_level]) {
                return upline;
            }
            upline = users[upline].upline;
        }
        return rootOwner;
    }

    function getMaxSpots(uint8 _program) public pure returns (uint8) {
        if (_program == 1 || _program == 3) return 3;
        if (_program == 7) return 4;
        if (_program == 10) return 5;
        if (_program == 13) return 6;
        if (_program == 2 || _program == 4 || _program == 8 || _program == 11) return 6;
        if (_program == 5 || _program == 9 || _program == 12 || _program == 14) return 14;
        if (_program == 6 || _program == 15) return 30;
        return 3;
    }

    function getLevelCost(uint8 _program, uint8 _level) public pure returns (uint256) {
        require(_program >= 1 && _program <= 15, "Invalid program");
        require(_level < 12, "Invalid level");
        uint256 base = uint256(_program - 1) * 120;
        uint256 step = uint256(_level + 1) * 10;
        return (base + step) * 1 ether;
    }

    function getServiceFee(uint8 _program) public pure returns (uint256) {
        require(_program >= 1 && _program <= 15, "Invalid program");
        return 0;
    }

    function sendAirdropTokens(address _recipient, uint256 _amount) internal {
        if (address(shineToken) != address(0) && address(shineToken).code.length > 0) {
            try shineToken.balanceOf(address(this)) returns (uint256 contractBal) {
                if (contractBal >= _amount) {
                    safeTransfer(shineToken, _recipient, _amount);
                } else if (contractBal > 0) {
                    safeTransfer(shineToken, _recipient, contractBal);
                } else if (airdropWallet != address(0)) {
                    try shineToken.transferFrom(airdropWallet, _recipient, _amount) {} catch {}
                }
            } catch {}
        }
    }

    function setShineToken(address _shineToken) external {
        require(msg.sender == rootOwner, "Only owner");
        shineToken = IERC20(_shineToken);
    }

    function setUsdtToken(address _usdtToken) external {
        require(msg.sender == rootOwner, "Only owner");
        usdtToken = IERC20(_usdtToken);
    }

    function distributeFunds(uint256 _cost, address _user, uint8 _program, uint8 _level) internal {
        uint256 tradingAmt = (_cost * 80) / 100;
        uint256 ownerAmt = (_cost * 10) / 100;

        uint256 up1Amt = (_cost * 5) / 100;
        uint256 up2Amt = (_cost * 3) / 100;
        uint256 up3Amt = (_cost * 2) / 100;

        if (tradingVault != address(0)) {
            safeTransfer(usdtToken, tradingVault, tradingAmt);
        } else {
            ownerAmt += tradingAmt;
        }

        address up1 = users[_user].upline;
        address up2 = up1 != address(0) ? users[up1].upline : address(0);
        address up3 = up2 != address(0) ? users[up2].upline : address(0);

        if (up1 != address(0) && users[up1].activeLevels[_program][_level] && !users[up1].matrices[_program][_level].blocked) {
            safeTransfer(usdtToken, up1, up1Amt);
        } else {
            ownerAmt += up1Amt;
        }

        if (up2 != address(0) && users[up2].activeLevels[_program][_level] && !users[up2].matrices[_program][_level].blocked) {
            safeTransfer(usdtToken, up2, up2Amt);
        } else {
            ownerAmt += up2Amt;
        }

        if (up3 != address(0) && users[up3].activeLevels[_program][_level] && !users[up3].matrices[_program][_level].blocked) {
            safeTransfer(usdtToken, up3, up3Amt);
        } else {
            ownerAmt += up3Amt;
        }

        safeTransfer(usdtToken, rootOwner, ownerAmt);

        emit Distribution(_user, tradingAmt, ownerAmt, up1Amt, up2Amt, up3Amt);
    }

    function distributeTradingProfit(address _user, uint256 _profitAmount) external {
        require(msg.sender == tradingVault || msg.sender == rootOwner, "Unauthorized");
        require(users[_user].isRegistered, "User not registered");
        require(_profitAmount > 0, "Zero profit");

        require(usdtToken.transferFrom(msg.sender, address(this), _profitAmount), "TransferFrom failed");

        uint256 userAmt = (_profitAmount * 80) / 100;
        uint256 ownerAmt = (_profitAmount * 5) / 100;
        uint256 uplineAmt = (_profitAmount * 5) / 100;
        uint256 airdropAmt = (_profitAmount * 5) / 100;
        uint256 charityAmt = (_profitAmount * 5) / 100;

        require(usdtToken.transfer(_user, userAmt), "User transfer failed");

        address up1 = users[_user].upline;
        if (up1 != address(0)) {
            require(usdtToken.transfer(up1, uplineAmt), "Upline transfer failed");
        } else {
            ownerAmt += uplineAmt;
        }

        require(usdtToken.transfer(rootOwner, ownerAmt), "Owner transfer failed");
        require(usdtToken.transfer(airdropWallet, airdropAmt), "Airdrop transfer failed");
        require(usdtToken.transfer(charityWallet, charityAmt), "Charity transfer failed");

        emit ProfitDistributed(_user, userAmt, uplineAmt, ownerAmt, airdropAmt, charityAmt);
    }

    function getMatrixState(address _user, uint8 _program, uint8 _level) external view returns (address currentReferrer, address[] memory referrals, uint256 reinvestCount, bool blocked) {
        Matrix storage m = users[_user].matrices[_program][_level];
        return (m.currentReferrer, m.referrals, m.reinvestCount, m.blocked);
    }

    function isUserLevelActive(address _user, uint8 _program, uint8 _level) external view returns (bool) {
        return users[_user].activeLevels[_program][_level];
    }

    function setVaults(address _ownerWallet, address _tradingVault, address _airdropWallet, address _charityWallet, address _feeWallet) external {
        require(msg.sender == rootOwner, "Only owner");
        rootOwner = _ownerWallet;
        tradingVault = _tradingVault;
        airdropWallet = _airdropWallet;
        charityWallet = _charityWallet;
        feeWallet = _feeWallet;
    }
}

interface IShineCore {
    function distributeTradingProfit(address _user, uint256 _profitAmount) external;
}

contract ShineVault {
    IERC20 public usdtToken;
    address public coreContract;
    address public botExecutor;
    address public rootOwner;

    event FundsReceived(address indexed sender, uint256 amount);
    event ProfitHarvested(address indexed user, uint256 profitAmount);

    modifier onlyAuthorized() {
        require(msg.sender == botExecutor || msg.sender == rootOwner, "Unauthorized");
        _;
    }

    constructor(address _usdtToken, address _coreContract, address _botExecutor) {
        usdtToken = IERC20(_usdtToken);
        coreContract = _coreContract;
        botExecutor = _botExecutor;
        rootOwner = msg.sender;
    }

    function withdrawTradingFunds(uint256 _amount) external onlyAuthorized {
        require(usdtToken.balanceOf(address(this)) >= _amount, "Insufficient vault balance");
        usdtToken.transfer(botExecutor, _amount);
        emit FundsReceived(botExecutor, _amount);
    }

    function harvestProfit(address _user, uint256 _profitAmount) external onlyAuthorized {
        require(usdtToken.balanceOf(address(this)) >= _profitAmount, "Insufficient vault balance");
        usdtToken.approve(coreContract, _profitAmount);
        IShineCore(coreContract).distributeTradingProfit(_user, _profitAmount);
        emit ProfitHarvested(_user, _profitAmount);
    }

    function setBotExecutor(address _newExecutor) external {
        require(msg.sender == rootOwner, "Only owner");
        botExecutor = _newExecutor;
    }

    function setCoreContract(address _newCore) external {
        require(msg.sender == rootOwner, "Only owner");
        coreContract = _newCore;
    }
}
