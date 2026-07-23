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
///        accrued(m)       = shares(m) * accPerShare - rewardDebt(m)
///
///      Whenever the share table changes (proposal execution or leave()) every
///      member's accrued amount is settled into `owed` first, so past earnings are
///      locked in at the old shares and future earnings accrue at the new ones.
///      New members start with rewardDebt equal to the current accumulator, so they
///      can never claim funds that arrived before they joined. Removed members keep
///      their `owed` balance and can claim it at any time.
///
///      Solvency invariant: for every token,
///        balanceOf(this) >= sum(owed) + sum(accrued) (up to wei-level rounding dust).
///      Rounding always favours the contract (members are floored), so the wallet
///      can never become insolvent; a few wei of dust per distribution change is
///      unrecoverable by design.
///
///      Token assumptions. Best with standard fixed-supply ERC20s (USDC, USDT,
///      DAI, WETH, ...). Degradation, not catastrophe, on non-standard tokens:
///        - fee-on-transfer: only the amount that actually lands is credited
///          (balance-based), so accounting stays consistent; claimers just bear
///          the token's fee.
///        - rebasing: a negative rebase reads as zero new funds and can leave the
///          last claimers of that token short. Avoid rebasing tokens.
///        - a token that later breaks (reverting balanceOf/transfer): confined to
///          that token — its funds may be frozen, but other tokens, governance and
///          leave() keep working. There is no token-removal path, so a broken
///          token stays whitelisted (harmlessly).
///        - blocklist tokens (USDC-style): a member blocked by the token issuer
///          cannot receive that token; their balance in it is stranded (no admin
///          rescue exists). Their other tokens are unaffected.
///      Native ETH is not supported — use WETH.
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
///        - One proposal is live at a time. A member can occupy that slot with junk
///          proposals to add friction, but an honest majority can always defeat a
///          junk proposal and push its own through, so this is griefing, not
///          capture. Already-earned funds (owed) are always claimable regardless.

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
        DISTRIBUTION, // replace the entire member/share table
        ADD_TOKEN     // whitelist an additional payment token
    }

    enum ProposalStatus {
        NONE,      // no proposal with this id
        ACTIVE,    // voting open
        PASSED,    // threshold reached, awaiting execution (until deadline)
        EXECUTED,
        DEFEATED,  // enough votes against that it can no longer pass
        EXPIRED,   // deadline passed without execution
        CANCELLED  // invalidated by a membership change (leave())
    }

    struct Proposal {
        ProposalType proposalType;
        address token;     // ADD_TOKEN proposals only
        address[] members; // DISTRIBUTION proposals only
        uint256[] shares;  // DISTRIBUTION proposals only
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
    /// @dev member => token => accumulator debt at the member's last settlement
    mapping(address => mapping(address => uint256)) public rewardDebt;
    /// @dev account => token => settled amount claimable at any time (survives removal)
    mapping(address => mapping(address => uint256)) public owed;

    /// @notice Shares of votesFor required for a proposal to pass (in share units,
    ///         strictly more than 50% and at most 100_000 = unanimity)
    uint256 public approvalThreshold;

    /// @notice Total number of proposals ever created; the votable one is the latest
    uint256 public proposalCount;
    mapping(uint256 => Proposal) private _proposals;

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
    function proposeDistribution(
        address[] calldata members,
        uint256[] calldata shares_
    ) external onlyMember returns (uint256 proposalId) {
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
    ///         cannot change while a proposal is active (execution and leave() both
    ///         end it), so vote weights are always consistent.
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
            _applyDistribution(p.members, p.shares);
        } else {
            _addToken(p.token);
        }
        emit ProposalExecuted(proposalId);
    }

    /// @notice Leaves the team unilaterally. The caller's accrued earnings are
    ///         settled (claimable forever via claim()), their shares are
    ///         redistributed pro-rata to the remaining members, and any live
    ///         proposal is cancelled since its vote weights are stale.
    function leave() external onlyMember {
        uint256 len = _memberList.length;
        if (len == 1) revert LastMemberCannotLeave();

        _cancelLiveProposal();

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
        uint256 acc = accPerShare[token];
        uint256 newFunds = _newFunds(token);
        if (newFunds > 0) {
            acc += (newFunds * ACC_PRECISION) / MAX_TOTAL_SHARES;
        }
        uint256 entitled = (_shares[account] * acc) / ACC_PRECISION;
        uint256 debt = rewardDebt[account][token];
        uint256 accrued = entitled > debt ? entitled - debt : 0;
        return owed[account][token] + accrued;
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

    /// @dev Funds received since the last sync. Hardened two ways:
    ///      - A balance DROP (rebasing/deflationary token) reads as zero new funds
    ///        instead of underflow-reverting (which is what bricked v2).
    ///      - A balanceOf that REVERTS (a token later paused, upgraded to revert, or
    ///        pointed at a self-destructed impl) reads as zero new funds instead of
    ///        propagating. Because sync() runs over every token inside
    ///        _applyDistribution, leave() and claimAll(), an unguarded revert here
    ///        would permanently freeze all membership changes and exits. With the
    ///        catch, a single broken token degrades to "no new funds" and the rest
    ///        of the wallet — other tokens, governance, leave() — keeps working.
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
        uint256 entitled = (_shares[account] * accPerShare[token]) / ACC_PRECISION;
        uint256 debt = rewardDebt[account][token];
        return entitled > debt ? entitled - debt : 0;
    }

    /// @dev Moves everything `account` is entitled to (settled + accrued) out of the
    ///      books and returns the amount. Assumes the token is already synced.
    function _harvest(address account, address token) private returns (uint256 amount) {
        uint256 accrued = _accrued(account, token);
        if (accrued > 0) {
            rewardDebt[account][token] = (_shares[account] * accPerShare[token]) / ACC_PRECISION;
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

        // 2. Settle every current member's accrued earnings into `owed`, then zero
        //    their shares. We deliberately do NOT reset rewardDebt here: a removed
        //    member has shares == 0, so _accrued() returns 0 for them regardless of
        //    any stale debt, and a member who stays (or is re-added) has their debt
        //    freshly rebaselined in step 3. Skipping the reset halves the storage
        //    writes on the hot path.
        for (uint256 i = 0; i < _memberList.length; i++) {
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

        // 3. Install the new table; baseline everyone's debt at the current
        //    accumulator so nobody picks up earnings from before this point.
        for (uint256 i = 0; i < newMembers.length; i++) {
            address member = newMembers[i];
            uint256 share = newShares[i];
            _shares[member] = share;
            _memberList.push(member);
            for (uint256 j = 0; j < tokenCount; j++) {
                address token = _tokenList[j];
                rewardDebt[member][token] = (share * accPerShare[token]) / ACC_PRECISION;
            }
            emit SharesSet(member, share);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function _createProposal(ProposalType proposalType) private returns (uint256 proposalId) {
        if (proposalCount > 0) {
            ProposalStatus status = proposalStatus(proposalCount - 1);
            if (status == ProposalStatus.ACTIVE || status == ProposalStatus.PASSED) {
                revert ProposalStillActive();
            }
        }
        proposalId = proposalCount++;
        Proposal storage p = _proposals[proposalId];
        p.proposalType = proposalType;
        p.deadline = uint64(block.timestamp + VOTING_PERIOD);
        emit ProposalCreated(proposalId, msg.sender, proposalType);
    }

    function _cancelLiveProposal() private {
        if (proposalCount == 0) return;
        uint256 latest = proposalCount - 1;
        ProposalStatus status = proposalStatus(latest);
        if (status == ProposalStatus.ACTIVE || status == ProposalStatus.PASSED) {
            _proposals[latest].cancelled = true;
            emit ProposalCancelled(latest);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL: VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _addToken(address token) private {
        if (token == address(0)) revert ZeroAddress();
        if (isSupportedToken[token]) revert DuplicateToken();
        isSupportedToken[token] = true;
        _tokenList.push(token);
        emit TokenAdded(token);
    }

    function _validateDistribution(address[] calldata members, uint256[] calldata shares_) private pure {
        uint256 len = members.length;
        if (len == 0) revert NoMembers();
        if (len > MAX_MEMBERS) revert TooManyMembers();
        if (shares_.length != len) revert LengthMismatch();

        uint256 total;
        for (uint256 i = 0; i < len; i++) {
            if (members[i] == address(0)) revert ZeroAddress();
            if (shares_[i] == 0) revert ZeroShares();
            for (uint256 j = 0; j < i; j++) {
                if (members[i] == members[j]) revert DuplicateMember();
            }
            total += shares_[i];
        }
        if (total != MAX_TOTAL_SHARES) revert InvalidShareTotal();
    }
}
