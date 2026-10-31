// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
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
    event FundsWithdrawn(address indexed receiver, uint256 amount);
    event ProfitHarvested(address indexed user, uint256 profitAmount);

    modifier onlyAuthorized() {
        require(msg.sender == botExecutor || msg.sender == rootOwner, "Unauthorized");
        _;
    }

    constructor(address _usdtToken, address _coreContract, address _botExecutor) {
        require(_usdtToken != address(0) && _coreContract != address(0) && _botExecutor != address(0), "Zero address");
        usdtToken = IERC20(_usdtToken);
        coreContract = _coreContract;
        botExecutor = _botExecutor;
        rootOwner = msg.sender;
    }

    function harvestProfit(address _user, uint256 _profitAmount) external onlyAuthorized {
        require(_profitAmount > 0, "Zero profit");
        require(usdtToken.balanceOf(address(this)) >= _profitAmount, "Insufficient vault balance");
        usdtToken.approve(coreContract, 0);
        usdtToken.approve(coreContract, _profitAmount);
        IShineCore(coreContract).distributeTradingProfit(_user, _profitAmount);
        emit ProfitHarvested(_user, _profitAmount);
    }

    function setBotExecutor(address _newExecutor) external {
        require(msg.sender == rootOwner, "Only owner");
        require(_newExecutor != address(0), "Zero address");
        botExecutor = _newExecutor;
    }

    function setCoreContract(address _newCore) external {
        require(msg.sender == rootOwner, "Only owner");
        require(_newCore != address(0), "Zero address");
        coreContract = _newCore;
    }

    function setOwner(address _newOwner) external {
        require(msg.sender == rootOwner, "Only owner");
        require(_newOwner != address(0), "Zero address");
        rootOwner = _newOwner;
    }

    function withdrawTradingFunds(uint256 _amount) external onlyAuthorized {
        require(usdtToken.balanceOf(address(this)) >= _amount, "Insufficient vault balance");
        usdtToken.transfer(botExecutor, _amount);
        emit FundsWithdrawn(botExecutor, _amount);
    }

    function depositTradingFunds(uint256 _amount) external {
        require(_amount > 0, "Zero amount");
        usdtToken.transferFrom(msg.sender, address(this), _amount);
        emit FundsReceived(msg.sender, _amount);
    }

    function emergencyWithdraw(address _token, uint256 _amount) external {
        require(msg.sender == rootOwner, "Only owner");
        if (_token == address(0)) {
            (bool success, ) = payable(rootOwner).call{value: address(this).balance}("");
            require(success, "Transfer failed");
        } else {
            IERC20(_token).transfer(rootOwner, _amount);
        }
    }

    receive() external payable {}
}
