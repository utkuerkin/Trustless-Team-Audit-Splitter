// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Trustless Team Audit Splitter v3
/// @author ljjeth (https://github.com/utkuerkin)
/// @notice Share-based team wallet for audit contest payouts. Earnings accrue to
///         members pro-rata via an accumulator (MasterChef-style), claims are pull
///         based, past earnings are settled automatically whenever shares change,
///         and membership is managed by share-weighted voting.
/// @dev Deployed as an EIP-1167 clone by TTASFactoryV3 and configured via initialize().
///
///      Accounting model, per token:
///        accPerShare      cumulative tokens-per-share, scaled by ACC_PRECISION
///        totalAccounted   lifetime tokens absorbed into accPerShare
///        totalReleased    lifetime tokens paid out to members
///        new funds        = balanceOf(this) + totalReleased - totalAccounted
///        grossScaled(m)   = shares(m) * accPerShare
///        accrued(m)       = (grossScaled(m) - rewardDebt(m)) / ACC_PRECISION
///
///      Whenever the share table changes (proposal execution or leave()) every
///      member's accrued amount is settled into `owed` first, so past earnings are
///      locked in at the old shares and future earnings accrue at the new ones.
///      rewardDebt is stored in scaled units. Subtraction therefore happens before
///      division, so independent floor operations across a share change can never
///      create more liabilities than the wallet owns. New members start with debt
///      equal to their exact scaled entitlement at the current accumulator, so they
///      can never claim funds that arrived before they joined. Removed members keep
///      their `owed` balance and can claim it at any time.
///
///      Solvency invariant for standard, non-rebasing ERC20s: for every token,
///        balanceOf(this) >= sum(owed) + sum(accrued) (up to wei-level rounding dust).
///      Rounding always favours the contract (members are floored once per share
///      epoch), so the wallet cannot become insolvent from accounting; a few wei of
///      dust per distribution change is unrecoverable by design.
///
///      Token assumptions. Best with standard fixed-supply ERC20s (USDC, USDT,
///      DAI, WETH, ...). Compatibility details and failure modes:
///        - fee-on-transfer: only the amount that actually lands is credited
///          (balance-based), so accounting stays consistent; claimers just bear
///          the token's fee.
///        - rebasing: a negative rebase reads as zero new funds and can leave the
///          last claimers of that token short. Avoid rebasing tokens.
///        - a token that later reverts in balanceOf: the revert is caught, so an
///          ordinary pause/break does not freeze other tokens, governance or
///          leave(). This isolation is not absolute: a hostile balanceOf can consume
///          nearly all forwarded gas or return arithmetic-extreme values, which can
///          still make operations that sync every token revert. Only whitelist
///          vetted tokens. There is no token-removal path.
///        - blocklist tokens (USDC-style): a member blocked by the token issuer
///          cannot receive that token; their balance in it is stranded (no admin
///          rescue exists). Their other tokens are unaffected.
///      Native ETH is not supported — use WETH.
///
///      Payout attribution limitation. Direct ERC20 transfers carry no contest or
///      epoch identifier. A payment is therefore split using the share table in
///      force when it arrives, even if it belongs to an older contest. Use a fresh
///      cheap clone per contest/payout agreement when delayed or overlapping payouts
///      could otherwise be assigned to the wrong team composition.
///
///      Governance trust model. This is a semi-trusted small-team tool, not a
///      trustless DAO. Voting is share-weighted and the approval threshold is fixed
///      at creation:
///        - A holder of >= threshold can rewrite the entire share table (including
///          handing 100% to a fresh address). Choose co-members accordingly.
///        - The threshold is immutable. Picking unanimity (100_000) means a single
///          lost/dark key can deadlock all future membership changes; a member's
///          only guaranteed escape is leave(). Prefer a supermajority over
///          unanimity unless every member's key liveness is assured.
///        - Each member may have at most one live proposal, so up to MAX_MEMBERS
///          proposals may proceed concurrently. This prevents one minority member
///          from monopolizing a global proposal slot. Any membership change cancels
///          every other live proposal because its recorded vote weights are stale.
///          Already-earned funds (owed) are always claimable regardless.

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/ITTASv3.sol";

contract TTASv3 is ITTASv3, Initializable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    enum ProposalType {
        // Replace the entire member/share table.
        DISTRIBUTION,
        // Whitelist an additional payment token.
        ADD_TOKEN
    }

    enum ProposalStatus {
        // No proposal with this id.
        NONE,
        // Voting is open.
        ACTIVE,
        // Threshold reached, awaiting execution until the deadline.
        PASSED,
        EXECUTED,
        // Enough votes oppose it that it can no longer pass.
        DEFEATED,
        // Deadline passed without execution.
        EXPIRED,
        // Invalidated by a membership or token-list change.
        CANCELLED
    }

    struct Proposal {
        ProposalType proposalType;
        address proposer;
        address token; // ADD_TOKEN proposals only
        address[] members; // DISTRIBUTION proposals only
        uint256[] shares; // DISTRIBUTION proposals only
        uint64 deadline;
        uint256 votesFor;
        uint256 votesAgainst;
        bool executed;
        bool cancelled;
        mapping(address => bool) hasVoted;
    }

    /// @dev Read-only mirror of Proposal (mappings can't be returned) plus the
    ///      derived status, for getProposal().
    struct ProposalView {
        ProposalType proposalType;
        address proposer;
        address token;
        address[] members;
        uint256[] shares;
        uint64 deadline;
        uint256 votesFor;
        uint256 votesAgainst;
        ProposalStatus status;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotMember();
    error NoMembers();
    error TooManyMembers();
    error LengthMismatch();
    error ZeroAddress();
    error ZeroShares();
    error DuplicateMember();
    error SelfMember();
    error InvalidShareTotal();
    error NoTokens();
    error TooManyTokens();
    error DuplicateToken();
    error InvalidThreshold();
    error UnsupportedToken();
    error NothingToClaim();
    error ProposalStillActive();
    error ProposalNotActive();
    error ProposalNotPassed();
    error AlreadyVoted();
    error LastMemberCannotLeave();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Version number of the contract
    uint256 public constant VERSION = 3;

    /// @notice Total shares, always fully distributed (100% = 100_000)
    uint256 private constant MAX_TOTAL_SHARES = 100_000;

    /// @notice Scaling factor for the per-share accumulator
    uint256 private constant ACC_PRECISION = 1e36;

    uint256 private constant MAX_MEMBERS = 12;
    uint256 private constant MAX_TOKENS = 10;

    /// @notice Proposals must be voted through and executed within this window
    uint256 public constant VOTING_PERIOD = 7 days;

    /*//////////////////////////////////////////////////////////////
                              STATE VARS
    //////////////////////////////////////////////////////////////*/

    /// @dev A member is any address with _shares[account] > 0.
    mapping(address => uint256) private _shares;
    address[] private _memberList;

    /// @notice Supported payment tokens
    mapping(address => bool) public isSupportedToken;
    address[] private _tokenList;

    // Accumulator accounting, per token (see contract-level natspec).
    mapping(address => uint256) public accPerShare;
    mapping(address => uint256) public totalAccounted;
    mapping(address => uint256) public totalReleased;
    /// @dev member => token => scaled entitlement already accounted for.
    ///      Unlike token-unit debt, scaled debt lets _accrued() subtract before
    ///      flooring and prevents cross-distribution rounding deficits.
    mapping(address => mapping(address => uint256)) public rewardDebt;
    /// @dev account => token => settled amount claimable at any time (survives removal)
    mapping(address => mapping(address => uint256)) public owed;

    /// @notice Shares of votesFor required for a proposal to pass (in share units,
    ///         strictly more than 50% and at most 100_000 = unanimity)
    uint256 public approvalThreshold;

    /// @notice Total number of proposals ever created
    uint256 public proposalCount;
    mapping(uint256 => Proposal) private _proposals;
    /// @dev proposer => proposal id + 1. Entries for terminal proposals are cleared
    ///      lazily when the proposer creates again or eagerly on invalidation.
    mapping(address => uint256) private _liveProposalPlusOne;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Synced(address indexed token, uint256 newFunds);
    event PaymentClaimed(address indexed token, address indexed account, uint256 amount);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, ProposalType proposalType);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event SharesSet(address indexed member, uint256 shares);
    event MemberLeft(address indexed member);
    event TokenAdded(address indexed token);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyMember() {
        if (_shares[msg.sender] == 0) revert NotMember();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @param members Initial member addresses (no duplicates, no zero address)
    /// @param shares_ Shares per member, must sum to exactly 100_000
    /// @param tokens Payment tokens to support (1..10, no duplicates)
    /// @param approvalThreshold_ votesFor needed to pass a proposal, in share units.
    ///        50_001 = simple majority, 100_000 = unanimity.
    function initialize(
        address[] calldata members,
        uint256[] calldata shares_,
        address[] calldata tokens,
        uint256 approvalThreshold_
    ) external initializer {
        _validateDistribution(members, shares_);

        if (tokens.length == 0) revert NoTokens();
        if (tokens.length > MAX_TOKENS) revert TooManyTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            _addToken(tokens[i]);
        }

        if (approvalThreshold_ <= MAX_TOTAL_SHARES / 2 || approvalThreshold_ > MAX_TOTAL_SHARES) {
            revert InvalidThreshold();
        }
        approvalThreshold = approvalThreshold_;

        for (uint256 i = 0; i < members.length; i++) {
            _shares[members[i]] = shares_[i];
            _memberList.push(members[i]);
            emit SharesSet(members[i], shares_[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          FUNDS: SYNC & CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Accrues any funds received since the last sync into the accumulator.
    ///         Permissionless; called automatically by claim() and on share changes.
    function sync(address token) public {
        if (!isSupportedToken[token]) revert UnsupportedToken();
        _sync(token);
    }

    /// @notice Claims everything msg.sender is owed in `token` (settled + accrued).
    ///         Also callable by former members to collect their settled balance.
    function claim(address token) external returns (uint256 amount) {
        if (!isSupportedToken[token]) revert UnsupportedToken();
        _sync(token);
        amount = _harvest(msg.sender, token);
        if (amount == 0) revert NothingToClaim();
        _payout(token, msg.sender, amount);
    }

    /// @notice Claims everything msg.sender is owed across all supported tokens.
    /// @dev Convenience wrapper: if any single transfer reverts (e.g. the caller is
    ///      blocklisted by one token), use claim(token) for the others instead.
    function claimAll() external returns (uint256 totalClaimed) {
        for (uint256 i = 0; i < _tokenList.length; i++) {
            address token = _tokenList[i];
            _sync(token);
            uint256 amount = _harvest(msg.sender, token);
            if (amount > 0) {
                _payout(token, msg.sender, amount);
                totalClaimed += amount;
            }
        }
        if (totalClaimed == 0) revert NothingToClaim();
    }

    /*//////////////////////////////////////////////////////////////
                              GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Proposes a complete new share table. Adding a member, removing a
    ///         member and changing percentages are all the same operation: list the
    ///         desired members with shares summing to 100_000. Anyone omitted is
    ///         removed (their already-earned funds stay claimable forever).
    function proposeDistribution(address[] calldata members, uint256[] calldata shares_)
        external
        onlyMember
        returns (uint256 proposalId)
    {
        _validateDistribution(members, shares_);
        proposalId = _createProposal(ProposalType.DISTRIBUTION);
        Proposal storage p = _proposals[proposalId];
        p.members = members;
        p.shares = shares_;
    }

    /// @notice Proposes adding a payment token to the whitelist.
    /// @dev Any balance already sitting in the token (e.g. a contest that paid in
    ///      an unlisted token) becomes distributable — split at the share table in
    ///      force when the proposal executes, since arrival time is unknowable.
    function proposeAddToken(address token) external onlyMember returns (uint256 proposalId) {
        if (token == address(0)) revert ZeroAddress();
        if (isSupportedToken[token]) revert DuplicateToken();
        if (_tokenList.length >= MAX_TOKENS) revert TooManyTokens();
        proposalId = _createProposal(ProposalType.ADD_TOKEN);
        _proposals[proposalId].token = token;
    }

    /// @notice Casts a share-weighted vote on the active proposal. Share weights
    ///         cannot change without cancelling every other live proposal, so vote
    ///         weights remain consistent even with concurrent proposals.
    function vote(uint256 proposalId, bool support) external onlyMember {
        if (proposalStatus(proposalId) != ProposalStatus.ACTIVE) revert ProposalNotActive();
        Proposal storage p = _proposals[proposalId];
        if (p.hasVoted[msg.sender]) revert AlreadyVoted();
        p.hasVoted[msg.sender] = true;

        uint256 weight = _shares[msg.sender];
        if (support) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }
        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /// @notice Executes a passed proposal. Callable by anyone while the proposal is
    ///         within its voting window; a passed proposal that is never executed
    ///         before the deadline simply expires.
    function executeProposal(uint256 proposalId) external {
        if (proposalStatus(proposalId) != ProposalStatus.PASSED) revert ProposalNotPassed();
        Proposal storage p = _proposals[proposalId];
        p.executed = true;

        if (p.proposalType == ProposalType.DISTRIBUTION) {
            // The executing proposal is already EXECUTED and is therefore skipped;
            // every other live proposal used the old vote weights and is cancelled.
            _cancelAllLiveProposals();
            _applyDistribution(p.members, p.shares);
        } else {
            _addToken(p.token);
            _clearProposalSlot(p.proposer, proposalId);
            _cancelInvalidTokenProposals(p.token);
        }
        emit ProposalExecuted(proposalId);
    }

    /// @notice Leaves the team unilaterally. The caller's accrued earnings are
    ///         settled (claimable forever via claim()), their shares are
    ///         redistributed pro-rata to the remaining members, and every live
    ///         proposal is cancelled since its vote weights are stale.
    function leave() external onlyMember {
        uint256 len = _memberList.length;
        if (len == 1) revert LastMemberCannotLeave();

        _cancelAllLiveProposals();

        uint256 remaining = MAX_TOTAL_SHARES - _shares[msg.sender];
        address[] memory newMembers = new address[](len - 1);
        uint256[] memory newShares = new uint256[](len - 1);

        uint256 k;
        uint256 total;
        uint256 largest;
        for (uint256 i = 0; i < len; i++) {
            address member = _memberList[i];
            if (member == msg.sender) continue;
            newMembers[k] = member;
            newShares[k] = (_shares[member] * MAX_TOTAL_SHARES) / remaining;
            total += newShares[k];
            if (newShares[k] > newShares[largest]) largest = k;
            k++;
        }
        // Flooring can leave a few share units unassigned; give them to the largest
        // remaining member so the table still sums to exactly 100%.
        newShares[largest] += MAX_TOTAL_SHARES - total;

        _applyDistribution(newMembers, newShares);
        emit MemberLeft(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function shares(address account) external view returns (uint256) {
        return _shares[account];
    }

    function totalShares() external pure returns (uint256) {
        return MAX_TOTAL_SHARES;
    }

    function getMembers() external view returns (address[] memory) {
        return _memberList;
    }

    function getTokens() external view returns (address[] memory) {
        return _tokenList;
    }

    /// @notice Everything `account` could claim in `token` right now, including
    ///         funds received but not yet synced.
    function claimable(address account, address token) external view returns (uint256) {
        if (!isSupportedToken[token]) revert UnsupportedToken();
        uint256 acc = accPerShare[token];
        uint256 newFunds = _newFunds(token);
        if (newFunds > 0) {
            acc += (newFunds * ACC_PRECISION) / MAX_TOTAL_SHARES;
        }
        uint256 grossScaled = _shares[account] * acc;
        uint256 debt = rewardDebt[account][token];
        uint256 accrued = grossScaled > debt ? (grossScaled - debt) / ACC_PRECISION : 0;
        return owed[account][token] + accrued;
    }

    /// @notice IDs of all currently ACTIVE or PASSED proposals. At most one entry
    ///         exists per current member, so both loops are bounded by MAX_MEMBERS.
    function getLiveProposalIds() external view returns (uint256[] memory ids) {
        uint256 memberCount = _memberList.length;
        uint256 count;
        for (uint256 i = 0; i < memberCount; i++) {
            uint256 plusOne = _liveProposalPlusOne[_memberList[i]];
            if (plusOne == 0) continue;
            ProposalStatus status = proposalStatus(plusOne - 1);
            if (status == ProposalStatus.ACTIVE || status == ProposalStatus.PASSED) count++;
        }

        ids = new uint256[](count);
        uint256 k;
        for (uint256 i = 0; i < memberCount; i++) {
            uint256 plusOne = _liveProposalPlusOne[_memberList[i]];
            if (plusOne == 0) continue;
            uint256 proposalId = plusOne - 1;
            ProposalStatus status = proposalStatus(proposalId);
            if (status == ProposalStatus.ACTIVE || status == ProposalStatus.PASSED) {
                ids[k++] = proposalId;
            }
        }
    }

    function proposalStatus(uint256 proposalId) public view returns (ProposalStatus) {
        if (proposalId >= proposalCount) return ProposalStatus.NONE;
        Proposal storage p = _proposals[proposalId];
        if (p.executed) return ProposalStatus.EXECUTED;
        if (p.cancelled) return ProposalStatus.CANCELLED;
        if (p.votesAgainst > MAX_TOTAL_SHARES - approvalThreshold) return ProposalStatus.DEFEATED;
        if (p.votesFor >= approvalThreshold) {
            return block.timestamp <= p.deadline ? ProposalStatus.PASSED : ProposalStatus.EXPIRED;
        }
        if (block.timestamp > p.deadline) return ProposalStatus.EXPIRED;
        return ProposalStatus.ACTIVE;
    }

    function getProposal(uint256 proposalId) external view returns (ProposalView memory) {
        Proposal storage p = _proposals[proposalId];
        return ProposalView({
            proposalType: p.proposalType,
            proposer: p.proposer,
            token: p.token,
            members: p.members,
            shares: p.shares,
            deadline: p.deadline,
            votesFor: p.votesFor,
            votesAgainst: p.votesAgainst,
            status: proposalStatus(proposalId)
        });
    }

    function hasVotedOn(uint256 proposalId, address account) external view returns (bool) {
        return _proposals[proposalId].hasVoted[account];
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Funds received since the last sync. Hardened against two common failures:
    ///      - A balance DROP (rebasing/deflationary token) reads as zero new funds
    ///        instead of underflow-reverting (which is what bricked v2).
    ///      - A balanceOf that REVERTS (a token later paused, upgraded to revert, or
    ///        pointed at a self-destructed impl) reads as zero new funds instead of
    ///        propagating. Because sync() runs over every token inside
    ///        _applyDistribution, leave() and claimAll(), an unguarded ordinary
    ///        revert here would freeze membership changes and exits.
    ///      This is deliberately not described as complete malicious-token isolation:
    ///      the external call has no gas cap, and arithmetic-extreme successful
    ///      return values can still revert inside this function or _sync().
    function _newFunds(address token) private view returns (uint256) {
        try IERC20(token).balanceOf(address(this)) returns (uint256 bal) {
            uint256 totalIn = bal + totalReleased[token];
            uint256 accounted = totalAccounted[token];
            return totalIn > accounted ? totalIn - accounted : 0;
        } catch {
            return 0;
        }
    }

    function _sync(address token) private {
        uint256 newFunds = _newFunds(token);
        if (newFunds == 0) return;
        accPerShare[token] += (newFunds * ACC_PRECISION) / MAX_TOTAL_SHARES;
        totalAccounted[token] += newFunds;
        emit Synced(token, newFunds);
    }

    /// @dev Accumulator earnings of `account` in `token` since their last settlement.
    function _accrued(address account, address token) private view returns (uint256) {
        uint256 grossScaled = _shares[account] * accPerShare[token];
        uint256 debt = rewardDebt[account][token];
        return grossScaled > debt ? (grossScaled - debt) / ACC_PRECISION : 0;
    }

    /// @dev Moves everything `account` is entitled to (settled + accrued) out of the
    ///      books and returns the amount. Assumes the token is already synced.
    function _harvest(address account, address token) private returns (uint256 amount) {
        uint256 accrued = _accrued(account, token);
        if (accrued > 0) {
            // Advance by whole paid units only. Any sub-token scaled remainder is
            // retained and can combine with later deposits while shares stay fixed.
            rewardDebt[account][token] += accrued * ACC_PRECISION;
        }
        amount = accrued + owed[account][token];
        if (owed[account][token] > 0) {
            owed[account][token] = 0;
        }
    }

    function _payout(address token, address to, uint256 amount) private {
        totalReleased[token] += amount;
        IERC20(token).safeTransfer(to, amount);
        emit PaymentClaimed(token, to, amount);
    }

    /// @dev Replaces the whole share table. Syncs every token and settles every
    ///      member's accrued earnings into `owed` first, so the change only affects
    ///      funds that arrive afterwards.
    function _applyDistribution(address[] memory newMembers, uint256[] memory newShares) private {
        uint256 tokenCount = _tokenList.length;

        // 1. Sync all tokens so unsynced funds accrue at the OLD shares.
        for (uint256 i = 0; i < tokenCount; i++) {
            _sync(_tokenList[i]);
        }

        // 2. Settle every current member's whole-token accrued earnings into `owed`,
        //    then zero their shares. Any sub-token scaled remainder is deliberately
        //    left as contract-favouring dust at the epoch boundary. We do NOT reset
        //    rewardDebt here: removed members have shares == 0, while members who
        //    stay or are re-added are freshly rebaselined in step 3.
        uint256 oldMemberCount = _memberList.length;
        for (uint256 i = 0; i < oldMemberCount; i++) {
            address member = _memberList[i];
            for (uint256 j = 0; j < tokenCount; j++) {
                address token = _tokenList[j];
                uint256 accrued = _accrued(member, token);
                if (accrued > 0) {
                    owed[member][token] += accrued;
                }
            }
            _shares[member] = 0;
        }
        delete _memberList;

        // 3. Install the new table; baseline everyone's debt at the exact scaled
        //    entitlement. Subtracting at scaled precision before later flooring is
        //    what prevents independent floor operations from creating insolvency.
        for (uint256 i = 0; i < newMembers.length; i++) {
            address member = newMembers[i];
            uint256 share = newShares[i];
            _shares[member] = share;
            _memberList.push(member);
            for (uint256 j = 0; j < tokenCount; j++) {
                address token = _tokenList[j];
                rewardDebt[member][token] = share * accPerShare[token];
            }
            emit SharesSet(member, share);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function _createProposal(ProposalType proposalType) private returns (uint256 proposalId) {
        uint256 previousPlusOne = _liveProposalPlusOne[msg.sender];
        if (previousPlusOne > 0) {
            ProposalStatus status = proposalStatus(previousPlusOne - 1);
            if (status == ProposalStatus.ACTIVE || status == ProposalStatus.PASSED) {
                revert ProposalStillActive();
            }
        }
        proposalId = proposalCount++;
        Proposal storage p = _proposals[proposalId];
        p.proposalType = proposalType;
        p.proposer = msg.sender;
        p.deadline = uint64(block.timestamp + VOTING_PERIOD);
        _liveProposalPlusOne[msg.sender] = proposalId + 1;
        emit ProposalCreated(proposalId, msg.sender, proposalType);
    }

    /// @dev Cancels every live proposal whose votes use the current share table.
    ///      One-live-proposal-per-member bounds this loop by MAX_MEMBERS.
    function _cancelAllLiveProposals() private {
        uint256 memberCount = _memberList.length;
        for (uint256 i = 0; i < memberCount; i++) {
            address proposer = _memberList[i];
            uint256 plusOne = _liveProposalPlusOne[proposer];
            if (plusOne == 0) continue;
            uint256 proposalId = plusOne - 1;
            ProposalStatus status = proposalStatus(proposalId);
            if (status == ProposalStatus.ACTIVE || status == ProposalStatus.PASSED) {
                _proposals[proposalId].cancelled = true;
                emit ProposalCancelled(proposalId);
            }
            delete _liveProposalPlusOne[proposer];
        }
    }

    /// @dev Adding a token invalidates concurrent proposals for the same token.
    ///      Reaching MAX_TOKENS invalidates every remaining ADD_TOKEN proposal.
    function _cancelInvalidTokenProposals(address addedToken) private {
        bool tokenListFull = _tokenList.length >= MAX_TOKENS;
        uint256 memberCount = _memberList.length;
        for (uint256 i = 0; i < memberCount; i++) {
            address proposer = _memberList[i];
            uint256 plusOne = _liveProposalPlusOne[proposer];
            if (plusOne == 0) continue;
            uint256 proposalId = plusOne - 1;
            Proposal storage candidate = _proposals[proposalId];
            if (candidate.proposalType == ProposalType.ADD_TOKEN && (candidate.token == addedToken || tokenListFull)) {
                ProposalStatus status = proposalStatus(proposalId);
                if (status == ProposalStatus.ACTIVE || status == ProposalStatus.PASSED) {
                    candidate.cancelled = true;
                    emit ProposalCancelled(proposalId);
                }
                delete _liveProposalPlusOne[proposer];
            }
        }
    }

    function _clearProposalSlot(address proposer, uint256 proposalId) private {
        if (_liveProposalPlusOne[proposer] == proposalId + 1) {
            delete _liveProposalPlusOne[proposer];
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _addToken(address token) private {
        if (token == address(0)) revert ZeroAddress();
        if (isSupportedToken[token]) revert DuplicateToken();
        if (_tokenList.length >= MAX_TOKENS) revert TooManyTokens();
        isSupportedToken[token] = true;
        _tokenList.push(token);
        emit TokenAdded(token);
    }

    function _validateDistribution(address[] calldata members, uint256[] calldata shares_) private view {
        uint256 len = members.length;
        if (len == 0) revert NoMembers();
        if (len > MAX_MEMBERS) revert TooManyMembers();
        if (shares_.length != len) revert LengthMismatch();

        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            if (members[i] == address(0)) revert ZeroAddress();
            if (members[i] == address(this)) revert SelfMember();
            if (shares_[i] == 0) revert ZeroShares();
            for (uint256 j = 0; j < i; j++) {
                if (members[i] == members[j]) revert DuplicateMember();
            }
            total += shares_[i];
        }
        if (total != MAX_TOTAL_SHARES) revert InvalidShareTotal();
    }
}
