// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Trustless Team Audit Splitter
/// @author ljjeth (https://github.com/utkuerkin)
/// @notice A trustless wallet for team audits with share-based distribution
/// @dev Original work: https://github.com/utkuerkin/trustless-team-audit-splitter

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract TTAS {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    /// @notice Mapping to track if an address is a member
    mapping(address => bool) private _isMember;
    /// @notice Member structure to track shares and released tokens
    struct Member {
        uint256 shares;
        mapping(address => uint256) released; // token => amount
    }

    /// @notice Payment snapshot structure to track token distributions
    struct PaymentSnapshot {
        uint256 timestamp;
        address token;
        uint256 amount;
        mapping(address => uint256) memberShares;  // Member shares at time of payment
        mapping(address => bool) isWithdrawn;      // Track who has withdrawn
        mapping(address => uint256) owedAmount;    // Amount owed to each member
    }

    /// @notice Types of proposals that can be created
    enum ProposalType {
        ADD_MEMBER,
        UPDATE_SHARES
    }

    /// @notice Proposal structure for governance actions
    struct Proposal {
        ProposalType proposalType;
        address newMember;           // Only used for ADD_MEMBER proposals
        address[] memberAddresses;   // Member addresses for share distribution
        uint256[] newShares;        // New share amounts
        uint256 votesFor;
        uint256 votesAgainst;
        bool executed;
        mapping(address => bool) hasVoted;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum total shares possible (100%)
    uint256 private constant MAX_TOTAL_SHARES = 100_000;

    /*//////////////////////////////////////////////////////////////
                              STATE VARS
    //////////////////////////////////////////////////////////////*/

    uint256 private _totalShares;
    mapping(address => Member) private _members;
    address[] private _memberList;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) private proposals;

    mapping(uint256 => PaymentSnapshot) private paymentSnapshots;
    uint256 public paymentCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event MemberAdded(address indexed member, uint256 shares);
    event SharesUpdated(address indexed member, uint256 newShares);
    event PaymentReleased(address indexed token, address indexed to, uint256 amount);
    event ProposalCreated(uint256 indexed proposalId, address indexed creator, ProposalType proposalType);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event PaymentRecorded(uint256 indexed snapshotId, address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address[] memory initialMembers, uint256[] memory initialShares) {
        require(initialMembers.length == initialShares.length, "Length mismatch");
        require(initialMembers.length > 0, "No members");

        // Calculate total shares to ensure 100%
        uint256 totalShareAmount;
        for (uint256 i = 0; i < initialMembers.length; i++) {
            totalShareAmount += initialShares[i];
        }
        require(totalShareAmount == MAX_TOTAL_SHARES, "Total shares must equal 100%");

        // Initialize members with their shares
        for (uint256 i = 0; i < initialMembers.length; i++) {
            _addMember(initialMembers[i], initialShares[i]);
            _isMember[initialMembers[i]] = true;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new payment snapshot using current token balance
    /// @param token Address of the ERC20 token to snapshot
    function recordPayment(address token) external {
        uint256 snapshotId = _recordPayment(token);
        require(snapshotId != type(uint256).max, "No new payments to record");
    }

    /// @notice Allows a member to claim their share from all unprocessed payments
    /// @param token Address of the ERC20 token to claim
    function releasePayment(address token) external {
        // First record any new unrecorded payments
        _recordPayment(token);
        
        // Process all unpaid snapshots for this member
        uint256 totalOwed;
        for(uint256 i = 0; i < paymentCount; i++) {
            PaymentSnapshot storage snapshot = paymentSnapshots[i];
            // Check if this snapshot has an unpaid amount for the caller
            if(snapshot.token == token && !snapshot.isWithdrawn[msg.sender] && snapshot.owedAmount[msg.sender] > 0) {
                totalOwed += snapshot.owedAmount[msg.sender];
                snapshot.isWithdrawn[msg.sender] = true;
            }
        }
        
        require(totalOwed > 0, "Nothing to claim");
        
        // Transfer owed tokens to the caller
        IERC20(token).safeTransfer(msg.sender, totalOwed);
        emit PaymentReleased(token, msg.sender, totalOwed);
    }

    /// @notice Creates a proposal for adding a new member
    /// @param _newMember Address of the member to add
    /// @param _newShares Array of new share amounts for all members (including new member)
    /// @param _memberAddresses Array of all member addresses (including new member)
    function createAddMemberProposal(
        address _newMember,
        address[] calldata _memberAddresses,
        uint256[] calldata _newShares
    ) external {
        require(shares(msg.sender) > 0, "Not a member");
        require(_memberAddresses.length == _newShares.length, "Length mismatch");
        require(_newMember != address(0), "Invalid address");
        require(!_isMember[_newMember], "Already member");
        
        // Create new proposal
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.proposalType = ProposalType.ADD_MEMBER;
        newProposal.newMember = _newMember;
        
        // Store member addresses and new shares
        for(uint256 i = 0; i < _memberAddresses.length; i++) {
            newProposal.memberAddresses.push(_memberAddresses[i]);
            newProposal.newShares.push(_newShares[i]);
        }
        
        emit ProposalCreated(proposalCount, msg.sender, ProposalType.ADD_MEMBER);
        proposalCount++;
    }

    /// @notice Creates a proposal for updating member shares
    /// @param _memberAddresses Array of member addresses
    /// @param _newShares Array of new share amounts
    function createUpdateSharesProposal(
        address[] calldata _memberAddresses,
        uint256[] calldata _newShares
    ) external {
        require(shares(msg.sender) > 0, "Not a member");
        require(_memberAddresses.length == _newShares.length, "Length mismatch");
        
        // Validate total shares equals 100%
        uint256 totalShareAmount;
        for(uint256 i = 0; i < _newShares.length; i++) {
            totalShareAmount += _newShares[i];
        }
        require(totalShareAmount == MAX_TOTAL_SHARES, "Total shares must equal 100%");
        
        // Create new proposal
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.proposalType = ProposalType.UPDATE_SHARES;
        
        // Store member addresses and new shares
        for(uint256 i = 0; i < _memberAddresses.length; i++) {
            require(_isMember[_memberAddresses[i]], "Not a member");
            newProposal.memberAddresses.push(_memberAddresses[i]);
            newProposal.newShares.push(_newShares[i]);
        }
        
        emit ProposalCreated(proposalCount, msg.sender, ProposalType.UPDATE_SHARES);
        proposalCount++;
    }

    /// @notice Allows a member to vote on a proposal
    /// @param _proposalId ID of the proposal
    /// @param _support Whether the member supports the proposal
    function vote(uint256 _proposalId, bool _support) external {
        require(shares(msg.sender) > 0, "Not a member");
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.hasVoted[msg.sender], "Already voted");
        require(!proposal.executed, "Already executed");
        
        proposal.hasVoted[msg.sender] = true;
        
        if (_support) {
            proposal.votesFor += shares(msg.sender);
        } else {
            proposal.votesAgainst += shares(msg.sender);
        }
        
        emit VoteCast(_proposalId, msg.sender, _support, shares(msg.sender));
        
        // Auto-execute if all members voted in favor
        if (proposal.votesFor == totalShares()) {
            executeProposal(_proposalId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function totalShares() public view returns (uint256) {
        return _totalShares;
    }

    function shares(address account) public view returns (uint256) {
        return _members[account].shares;
    }

    function getMembers() public view returns (address[] memory) {
        return _memberList;
    }

    /// @notice Returns proposal details except for the hasVoted mapping
    function getProposal(uint256 proposalId) public view returns (
        ProposalType proposalType,
        address targetAddress,
        uint256[] memory newShares,
        address[] memory memberAddresses,
        uint256 votesFor,
        uint256 votesAgainst,
        bool executed
    ) {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.proposalType,
            proposal.newMember,
            proposal.newShares,
            proposal.memberAddresses,
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.executed
        );
    }

    /// @notice View function to check owed amount for a specific payment
    function getOwedAmount(uint256 snapshotId, address account) external view returns (uint256) {
        return paymentSnapshots[snapshotId].owedAmount[account];
    }

    /// @notice View function to check if payment has been withdrawn
    function isPaymentWithdrawn(uint256 snapshotId, address account) external view returns (bool) {
        return paymentSnapshots[snapshotId].isWithdrawn[account];
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal function to record new payments and create snapshots
    /// @param token Address of the ERC20 token to record
    /// @return snapshotId ID of the new snapshot if created, or type(uint256).max if no new payment
    function _recordPayment(address token) internal returns (uint256) {
        // Get current balance and calculate new payments
        uint256 currentBalance = IERC20(token).balanceOf(address(this));
        uint256 previouslyRecorded;
        
        // Sum up all previously recorded payments
        for(uint256 i = 0; i < paymentCount; i++) {
            if(paymentSnapshots[i].token == token) {
                previouslyRecorded += paymentSnapshots[i].amount;
            }
        }
        
        // Calculate new unrecorded amount
        uint256 newAmount = currentBalance - previouslyRecorded;
        if(newAmount == 0) {
            return type(uint256).max;
        }
        
        // Create new payment snapshot
        uint256 snapshotId = paymentCount;
        PaymentSnapshot storage snapshot = paymentSnapshots[snapshotId];
        
        snapshot.timestamp = block.timestamp;
        snapshot.token = token;
        snapshot.amount = newAmount;
        
        // Record current shares and calculate owed amounts for all members
        for (uint256 i = 0; i < _memberList.length; i++) {
            address member = _memberList[i];
            snapshot.memberShares[member] = _members[member].shares;
            snapshot.owedAmount[member] = (newAmount * _members[member].shares) / MAX_TOTAL_SHARES;
        }
        
        paymentCount++;
        emit PaymentRecorded(snapshotId, token, newAmount);
        return snapshotId;
    }

    /// @notice Executes a proposal that has received sufficient votes
    /// @param _proposalId ID of the proposal to execute
    function executeProposal(uint256 _proposalId) internal {
        Proposal storage proposal = proposals[_proposalId];
        require(!proposal.executed, "Already executed");
        require(proposal.votesFor == totalShares(), "Insufficient votes");
        
        // Update all shares according to proposal
        _totalShares = 0;
        
        if (proposal.proposalType == ProposalType.ADD_MEMBER) {
            require(!_isMember[proposal.newMember], "Already member");
            _isMember[proposal.newMember] = true;
            _memberList.push(proposal.newMember);
            emit MemberAdded(proposal.newMember, proposal.newShares[proposal.memberAddresses.length - 1]);
        }
        
        for(uint256 i = 0; i < proposal.memberAddresses.length; i++) {
            address member = proposal.memberAddresses[i];
            uint256 newShare = proposal.newShares[i];
            
            _members[member].shares = newShare;
            _totalShares += newShare;
            
            if(proposal.proposalType == ProposalType.UPDATE_SHARES) {
                emit SharesUpdated(member, newShare);
            }
        }
        
        require(_totalShares == MAX_TOTAL_SHARES, "Total shares must equal 100%");
        proposal.executed = true;
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal function to add a new member
    /// @param account Address of the new member
    /// @param shareAmount Number of shares to assign to the member
    function _addMember(address account, uint256 shareAmount) private {
        require(account != address(0), "Zero address");
        require(shareAmount > 0, "Zero shares");
        require(!_isMember[account], "Already member");
        require(_totalShares + shareAmount <= MAX_TOTAL_SHARES, "Exceeds max shares");

        _members[account].shares = shareAmount;
        _memberList.push(account);
        _totalShares += shareAmount;

        emit MemberAdded(account, shareAmount);
    }
}
