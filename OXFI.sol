// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.8;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import './OXFIvault.sol';
import './IPancakeRouter.sol';
import './IPancakePair.sol';
import './IPancakeFactory.sol';

/*

     ____   __   __  ______   _____ 
    / __ \  \ \ / / |  ____| |_   _|
   | |  | |  \ V /  | |__      | |  
   | |  | |   > <   |  __|     | |  
   | |__| |  / . \  | |       _| |_ 
    \____/  /_/ \_\ |_|      |_____|

   Website: https://oxfi.app/
   Telegram: https://t.me/OXFIcommunity
   Build by: KISHIELD.com                
   Contract: OXFI.sol

   STATE: PRODUCTION
*/

contract OXFI is IERC20, Ownable, AccessControl {
	using SafeMath for uint256;

	string constant _name = 'oxfinance'; // Name
	string constant _symbol = 'OXFI';    // Symbol
	uint8 constant _decimals = 18;       // Decimals

	uint256 _totalSupply = 1_000_000 ether;      // Total Supply
	uint256 _fixedTotalSupply = 1_000_000 ether; // Fixed Total Supply to manage static allowances
	uint256 public _maxTxAmount = 1000 ether;    // Initial tx amount is 1000 to stop bots

	mapping(address => uint256) _balances;
	mapping(address => mapping(address => uint256)) _allowances;

	mapping(address => bool) isFeeExempt;
	mapping(address => bool) isTxLimitExempt;

	// OXFI Buy Taxes
	uint256 public vaultFee = 70; // 7% will be added to the Vault as BUSD
	uint256 public marketFee = 30; // 3% will go to the market wallet address

	// OXFI Sell Taxes
	uint256 public destroyFee = 50; // 5% will be destroyed decreasing the total supply
	uint256 public liquidityFee = 50; // 5% will be added to the liquidity pool

	// OXFI Trackers
	uint256 public vaultFeeTracker;
	uint256 public liquidityFeeTracker;

	// OXFI Counters
	uint256 public destroyedTokenCount;

	// Contract Use
	uint256 constant feeDenominator = 1000;

	// External wallets
	address public autoLiquidityReceiver;
	address public marketingFeeReceiver;

	// Self Explanatory
	OXFIvault public immutable vault;
	IPancakeRouter public router;
	address public pair;

	// ERC20s
	// BUSD testnet 0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7
	// BUSD mainnet 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56
	address private WBNB;
	IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

	// Access Control (Vault can destroy tokens)
	bytes32 public constant DESTROYER_ROLE = keccak256('DESTROYER_ROLE');

	// Threshold for vault deposit and liquidity injection
	uint256 public swapThreshold = _totalSupply / 2000; // 0.05%

	// Handle Swap state
	bool inSwap;

	modifier swapping() {
		inSwap = true;
		_;
		inSwap = false;
	}

	event AutoLiquify(uint256 indexed amountBNB, uint256 indexed amountOXFI);
	event VaultDeposit(uint256 indexed deposited);
	event SetTxLimit(uint256 indexed maxTxAmount);
	event SetBuyFeePercent(uint256 indexed vaultFee, uint256 indexed marketFee);
	event SetSellFeePercent(uint256 indexed destroyFee, uint256 indexed liquidityFee);

	bool public swapEnabled = true; // for swap between OXFI and BUSD (not trading)

	constructor() {
		// mainet router 0x10ED43C718714eb63d5aA57B78B54704E256024E
		// testnet router 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3

		// Set the owner to OXFI
		transferOwnership(0xE67d07170Fe31Aa31c8304f5ebCEA8CB209309D6);

		// Create vault and set role
		vault = new OXFIvault(address(this), 0x10ED43C718714eb63d5aA57B78B54704E256024E, owner());
		_setupRole(DESTROYER_ROLE, address(vault));

		// set up router and create pair WBNB -> OXFI
		router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
		WBNB = router.WETH();
		pair = IPancakeFactory(router.factory()).createPair(WBNB, address(this));

		// Allow the router to use all the tokens
		_allowances[address(this)][address(router)] = _fixedTotalSupply;

		// Set up external wallets
		// Hardhat 0x70997970C51812dc3A010C7d01b50e0d17dc79C8
		// Testnet 0x0600061016d090f004925000D80008e0fA1610c0
		marketingFeeReceiver = 0x51e70acd3B1BbDF82f664654a81D4A2C98D1b91c;
		autoLiquidityReceiver = 0x0957bE1AC1018a615e58B19c543b7830E88B0Eee;

		// Exemptions and limits
		isFeeExempt[owner()] = true;
		isTxLimitExempt[owner()] = true;
		isFeeExempt[msg.sender] = true;
		isTxLimitExempt[msg.sender] = true;

		// Required allowances
		approve(address(router), _fixedTotalSupply);
		approve(address(pair), _fixedTotalSupply);

		// Mint the tokens
		_balances[owner()] = _totalSupply;
		emit Transfer(address(0), owner(), _totalSupply);
	}

	receive() external payable {}

	/*  
        OXFI Unique function, Users can redeem BUSD using OXFI,
        the tokens used are destroyed, to avoid an extra approve
        OXFI Vault alters the balance in low-level, Only the vault
        can call this function.
    */
	function destroy(address user, uint256 amount) external returns (bool) {
		require(hasRole(DESTROYER_ROLE, msg.sender), 'OXFI: Caller is not OXFI vault');
		// destroy tokens
		_totalSupply = _totalSupply.sub(amount);
		// remove tokens from user
		_balances[user] = _balances[user].sub(amount);
		emit Transfer(user, address(0), amount);
		// update total destroyed tokens tracker
		destroyedTokenCount = destroyedTokenCount.add(amount);

		return true;
	}

	function totalSupply() external view returns (uint256) {
		return _totalSupply;
	}

	function decimals() external pure returns (uint8) {
		return _decimals;
	}

	function symbol() external pure returns (string memory) {
		return _symbol;
	}

	function name() external pure returns (string memory) {
		return _name;
	}

	function balanceOf(address account) public view override returns (uint256) {
		return _balances[account];
	}

	function allowance(address holder, address spender) external view override returns (uint256) {
		return _allowances[holder][spender];
	}

	function approve(address spender, uint256 amount) public override returns (bool) {
		_allowances[msg.sender][spender] = amount;
		emit Approval(msg.sender, spender, amount);
		return true;
	}

	function approveMax(address spender) external returns (bool) {
		return approve(spender, _fixedTotalSupply);
	}

	function transfer(address recipient, uint256 amount) external override returns (bool) {
		return _transferFrom(msg.sender, recipient, amount);
	}

	function transferFrom(
		address sender,
		address recipient,
		uint256 amount
	) external override returns (bool) {
		if (_allowances[sender][msg.sender] != _fixedTotalSupply) {
			_allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(
				amount,
				'Insufficient Allowance'
			);
		}

		return _transferFrom(sender, recipient, amount);
	}

	function _transferFrom(
		address sender,
		address recipient,
		uint256 amount
	) internal returns (bool) {

		if (!isTxLimitExempt[sender] && !isTxLimitExempt[recipient]) {
			// Max tx amount
			require(amount <= _maxTxAmount, "OXFI: tx limit exceeded");
        }

		if (inSwap) {
			return _basicTransfer(sender, recipient, amount);
		}

		if (shouldDepositToVault()) {
			_depositToVault();
		}

		if (shouldAddLiquidity()) {
			_addLiquidity();
		}

		_balances[sender] = _balances[sender].sub(amount, 'Insufficient Balance');

		uint256 tFee;
		if (isFeeExempt[sender] || isFeeExempt[recipient]) {
			_balances[recipient] = _balances[recipient].add(amount);
			emit Transfer(sender, recipient, amount);
		}
		// SELL handler
		else if (recipient == pair) {
			// calculate fee amount for sell
			tFee = amount.mul(destroyFee.add(liquidityFee)).div(feeDenominator);
			// sent the tokens to the recipient
			_balances[recipient] = _balances[recipient].add(amount.sub(tFee));
			emit Transfer(sender, recipient, amount.sub(tFee));
			// take the fee
			_takeSellFee(sender, amount);
		}
		// BUY && TRANSFER
		else {
			// calculate fee amount for buy or transfer
			tFee = amount.mul(vaultFee.add(marketFee)).div(feeDenominator);
			// sent the tokens to the recipient
			_balances[recipient] = _balances[recipient].add(amount.sub(tFee));
			emit Transfer(sender, recipient, amount.sub(tFee));
			// take the fee
			_takeBuyFee(sender, amount);
		}
		return true;
	}

	function _basicTransfer(
		address sender,
		address recipient,
		uint256 amount
	) internal returns (bool) {
		_balances[sender] = _balances[sender].sub(amount, 'Insufficient Balance');
		_balances[recipient] = _balances[recipient].add(amount);
		emit Transfer(sender, recipient, amount);
		return true;
	}

	function _takeBuyFee(address sender, uint256 tAmount) internal {
		uint256 vFee = tAmount.mul(vaultFee).div(1e3);
		uint256 mFee = tAmount.mul(marketFee).div(1e3);
		_balances[address(this)] = _balances[address(this)].add(vFee);
		// marketing fee
		_balances[marketingFeeReceiver] = _balances[marketingFeeReceiver].add(mFee);
		// vault tracker
		vaultFeeTracker = vaultFeeTracker.add(vFee);
		emit Transfer(sender, address(this), vFee);
		emit Transfer(sender, marketingFeeReceiver, mFee);
	}

	function _takeSellFee(address sender, uint256 tAmount) internal {
		uint256 dFee = tAmount.mul(destroyFee).div(1e3);
		uint256 lFee = tAmount.mul(liquidityFee).div(1e3);
		_balances[address(this)] = _balances[address(this)].add(lFee);
		// destroy tokens
		_totalSupply = _totalSupply.sub(dFee);
		// liquidity tracker
		liquidityFeeTracker = liquidityFeeTracker.add(lFee);
		// total destroyed tokens tracker
		destroyedTokenCount = destroyedTokenCount.add(dFee);
		emit Transfer(sender, address(this), lFee);
		emit Transfer(sender, address(0), dFee);
	}

	function shouldDepositToVault() internal view returns (bool) {
		// always deposit if the balance is > 0.
		return msg.sender != pair && !inSwap && swapEnabled && vaultFeeTracker > swapThreshold;
	}

	function shouldAddLiquidity() internal view returns (bool) {
		// add liquidity once the liquidityFeeTracker is equal or over 0.005% of the supply
		return msg.sender != pair && !inSwap && swapEnabled && liquidityFeeTracker >= swapThreshold;
	}

	function _depositToVault() internal swapping {
		// get the number of tokens from vault fee
		uint256 amountToSwap = vaultFeeTracker;
		// reset the tracker
		vaultFeeTracker = 0;

		// capture the vault contract current BUSD balance.
		// this is so that we can capture exactly the amount of BUSD that the
		// we are depositing to the Vault
		uint256 balanceBefore = BUSD.balanceOf(address(vault));

		// swap tokens for BUSD
		// generate the uniswap pair path of token -> busd
		address[] memory path = new address[](3);
		path[0] = address(this);
		path[1] = WBNB;
		path[2] = address(BUSD);

		// make the swap and send the tokens to the vault
		router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
			amountToSwap,
			0,
			path,
			address(vault),
			block.timestamp
		);

		// how much BUSD did we just deposited?
		uint256 balanceAfter = BUSD.balanceOf(address(vault));
		uint256 deposited = balanceAfter.sub(balanceBefore);

		emit VaultDeposit(deposited);
	}
	function _addLiquidity() internal swapping {
		// split the contract balance into halves
		uint256 half = liquidityFeeTracker.div(2);
		uint256 otherHalf = liquidityFeeTracker.sub(half);
		// reset the tracker
		liquidityFeeTracker = 0;

		// capture the contract's current BNB balance.
		// this is so that we can capture exactly the amount of BNB that the
		// swap creates, and not make the liquidity event include any BNB that
		// has been manually sent to the contract
		uint256 initialBalance = address(this).balance;

		// swap tokens for BNB
		// generate the uniswap pair path of token -> wbnb
		address[] memory path = new address[](2);
		path[0] = address(this);
		path[1] = router.WETH();

		// make the swap
		router.swapExactTokensForETHSupportingFeeOnTransferTokens(
			half,
			0, // accept any amount of BNB
			path,
			address(this),
			block.timestamp
		);

		// how much BNB did we just swap into?
		uint256 newBalance = address(this).balance.sub(initialBalance);

		// add liquidity to PancakeSwap
		router.addLiquidityETH{value: newBalance}(
			address(this),
			otherHalf,
			0, // slippage is unavoidable
			0, // slippage is unavoidable
			autoLiquidityReceiver,
			block.timestamp
		);

		emit AutoLiquify(newBalance, otherHalf);
	}

	function setIsFeeExempt(address holder, bool exempt) external onlyOwner {
		isFeeExempt[holder] = exempt;
	}

	function setIsTxLimitExempt(address holder, bool exempt) external onlyOwner {
		isTxLimitExempt[holder] = exempt;
	}

	//only owner can change BuyFeePercentages any time after deployment
	function setBuyFeePercent(uint256 _vaultFee, uint256 _marketFee) external onlyOwner {
		require(_vaultFee.add(_marketFee) <= 100, 'OXFI: Buy fees cannot be over 10%');
		vaultFee = _vaultFee;
		marketFee = _marketFee;
		emit SetBuyFeePercent(vaultFee, marketFee);
	}

	//only owner can change SellFeePercentages any time after deployment
	function setSellFeePercent(uint256 _destroyFee, uint256 _liquidityFee) external onlyOwner {
		require(_destroyFee.add(_liquidityFee) <= 100, 'OXFI: Sell fees cannot be over 10%');
		destroyFee = _destroyFee;
		liquidityFee = _liquidityFee;
		emit SetSellFeePercent(destroyFee, liquidityFee);
	}

	function setFeeReceivers(address _autoLiquidityReceiver, address _marketingFeeReceiver)
		external
		onlyOwner
	{
		autoLiquidityReceiver = _autoLiquidityReceiver;
		marketingFeeReceiver = _marketingFeeReceiver;
	}

	function setSwapBackSettings(bool _enabled, uint256 _amount) external onlyOwner {
		swapEnabled = _enabled; 
		swapThreshold = _amount;
	}

	function getOxfiPrice() external view returns (uint[] memory amounts) {
		// generate the uniswap pair path of OXFI -> BUSD
		address[] memory path = new address[](3);
		path[0] = address(this);
		path[1] = WBNB;
		path[2] = address(BUSD);

		return router.getAmountsOut(1 ether, path);
	}

	function setTxLimit(uint256 amount) external onlyOwner {
		require(amount >= 10_000); // minimum tx amount is 0.01%
		_maxTxAmount = amount * 10**18;
		emit SetTxLimit(_maxTxAmount);
	}
}
