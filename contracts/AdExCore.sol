pragma solidity 0.4.25;
pragma experimental ABIEncoderV2;

import "./libs/SafeMath.sol";
import "./libs/SignatureValidator.sol";
import "./libs/BidLibrary.sol";
import "./libs/CommitmentLibrary.sol";
import "./AdExCoreInterface.sol";

// Things we can static-analyze
// 1) Every time we check if the state is active, we also check delivery commitment hash
// 2) every time we check the state, the function should either revert or change the state
// 3) state transition: deliveryCommitmentStart locks up tokens, then Finalize and Timeout can always unlock
// 4) every time we transition out of BidState.Active, we should delete commitments[]

contract AdExCore is AdExCoreInterface {
	using SafeMath for *;
	using BidLibrary for BidLibrary.Bid;
	using CommitmentLibrary for CommitmentLibrary.Commitment;

	// assets (tokenAddr => (account => uint))
	mapping (address => mapping (address => uint)) private balances;

 	// bidId => bidState
	mapping (bytes32 => BidState) public states;
	// bidId => commitmentId
	mapping (bytes32 => bytes32) public commitments;

	// Public Functions
	constructor() public {}

	// @TODO: ERC20 hack
	function deposit(address token, uint amount)
		external
	{
		balanceAdd(token, msg.sender, amount);
		require(new ERC20(token).transferFrom(msg.sender, address(this), amount));

		LogDeposit(msg.sender, token, amount);
	}

	function withdraw(address token, uint amount)
		external
	{
		require(amount <= balances[token][msg.sender]);

		balanceSub(token, msg.sender, amount);
		require(new ERC20(token).transfer(msg.sender, amount));

		LogWithdrawal(msg.sender, token, amount);
	}

	// Shim that will be removed once solidity supports external functions with structs in their args
	// Then, we will delete the next 4 functions and just rename all *Internal and change their visibility
	function bidCancel(uint[7] bidValues, address[] bidValidators, uint[] bidValidatorRewards) external {
		bidCancelInternal(BidLibrary.fromValues(bidValues, bidValidators, bidValidatorRewards));
	}
	function commitmentStart(uint[7] bidValues, address[] bidValidators, uint[] bidValidatorRewards, bytes signature, address extraValidator, uint extraValidatorReward) external {
		commitmentStartInternal(BidLibrary.fromValues(bidValues, bidValidators, bidValidatorRewards), signature, extraValidator, extraValidatorReward);
	}
	function commitmentTimeout(bytes32[6] cValues, address[] cValidators, uint[] cValidatorRewards) external {
		commitmentTimeoutInternal(CommitmentLibrary.fromValues(cValues, cValidators, cValidatorRewards));
	}
	function commitmentFinalize(bytes32[6] cValues, address[] cValidators, uint[] cValidatorRewards, bytes32[] signatures, bytes32 vote) external {
		commitmentFinalizeInternal(CommitmentLibrary.fromValues(cValues, cValidators, cValidatorRewards), signatures, vote);
	}

	// Internal functions
	function bidCancelInternal(BidLibrary.Bid memory bid)
		internal
	{
		require(msg.sender == bid.advertiser);

		bytes32 memory bidId = bid.hash();

		require(states[bidId] == BidState.Unknown);
		states[bidId] = BidState.Canceled;

		LogBidCanceled(bidId);
	}

	function commitmentStartInternal(BidLibrary.Bid memory bid, bytes signature, address extraValidator, uint extraValidatorReward)
		internal
	{
		bytes32 memory bidId = bid.hash();
		require(states[bidId] == BidState.Unknown);

		// Check if validly signed and advertiser has the funds
		require(SignatureValidator.isValidSignature(bidId, bid.advertiser, signature));
		require(balances[bid.tokenAddr][bid.advertiser] >= bid.tokenAmount);

		DeliveryCommitment memory commitment = DeliveryCommitment.fromBid(bid, msg.sender, extraValidator, extraValidatorReward);
		states[bidId] = BidState.Active;
		commitment[bidId] = commitment.hash();

		balanceSub(bid.tokenAddr, bid.advertiser, bid.tokenAmount);
		balanceAdd(bid.tokenAddr, address(this), bid.tokenAmount);
		// @TODO log event
	}

	function commitmentTimeoutInternal(CommitmentLibrary.Commitment memory commitment)
		internal
	{
		require(states[commitment.bidId] == BidState.Active);
		require(commitments[commitment.bidId] == commitment.hash());
		require(now > commitment.validUntil);

		states[commitment.bidId] = BidState.DeliveryTimedOut;
		delete commitment[commitment.bidId];

		balanceSub(commitment.tokenAddr, address(this), commitment.tokenAmount);
		balanceAdd(commitment.tokenAddr, commitment.advertiser, commitment.tokenAmount);

		// @TODO log event
	}

	function commitmentFinalizeInternal(CommitmentLibrary.Commitment memory commitment, bytes32[] signatures, bytes32 vote)
		internal
	{
		require(states[commitment.bidId] == BidState.Active);
		require(commitment[commitment.bidId] == commitment.hash());
		// @AUDIT: ensure the sum of all balanceSub/balanceAdd is 0
		// @TODO check if it's not timed out (??)

		// Unlock the funds
		balanceSub(commitment.tokenAddr, address(this), commitment.tokenAmount);

		bytes32 memory hashToSign = keccak256(commitment.hash(), vote);
		uint memory remaining = commitment.tokenAmount;
		uint memory votes = 0;
		uint memory sigLen = signatures.length;
		require(sigLen <= commitment.validators.length);
		for (uint i=0; i<sigLen; i++) {
			if (signatures[i] == 0x0) {
				continue;
			}
			if (SignatureValidator.isValidSignature(hashToSign, commitment.validators[i], signatures[i])) {
				votes++;
				balanceAdd(commitment.tokenAddr, commitment.validators[i], commitment.validatorReward[i]);
				// if the sum of all validatorRewards is more than tokenAmount, this will revert eventually
				remaining = remaining.sub(commitment.validatorReward[i]);
			}
		}

		// Always require supermajority; we're checking the same vote, so this means 2/3 validators signed the same vote
		require(votes*3 >= commitment.validators.length*2);

		if (vote != 0x0) {
			states[commitment.bidId] = BidState.DeliverySucceeded;
			balanceAdd(commitment.tokenAddr, commitment.publisher, remaining);
		} else {
			states[commitment.bidId] = BidState.DeliveryFailed;
			balanceAdd(commitment.tokenAddr, commitment.advertiser, remaining);
		}
		delete commitments[commitment.bidId];

		// @TODO: log event
	}

	// A few internal helpers
	function balanceSub(address token, address acc, uint amount) internal {
		balances[token][acc] = balances[token][acc].sub(amount);
	}
	function balanceAdd(address token, address acc, uint amount) internal {
		balances[token][acc] = balances[token][acc].add(amount);
	}
}
