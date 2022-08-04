%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.starknet.common.syscalls import (
    get_caller_address,
    get_contract_address,
    get_block_number,
    get_block_timestamp,
)

from starkware.cairo.common.bool import FALSE, TRUE
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math import (
    assert_not_zero,
    assert_not_equal,
    assert_nn_le,
    split_felt,
    assert_lt_felt,
    assert_le_felt,
    assert_le,
    unsigned_div_rem,
    signed_div_rem,
)
from starkware.cairo.common.uint256 import Uint256, uint256_eq, uint256_le, uint256_lt
from openzeppelin.security.safemath import SafeUint256
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.math_cmp import is_le, is_not_zero, is_nn, is_in_range
from openzeppelin.token.ERC20.interfaces.IERC20 import IERC20
from openzeppelin.access.ownable import Ownable
from openzeppelin.security.pausable import Pausable
from openzeppelin.security.reentrancy_guard import ReentrancyGuard
from Libraries.DolvenApprover import DolvenApprover
from Interfaces.IDolvenValidator import IDolvenValidator
from Interfaces.IDolvenVotingStrategy import IDolvenVotingStrategy
from Interfaces.ITimelock import ITimelockController

# # Storages

# Status of proposal
const CANCELLED = 0
const SUCCESS = 1
const PENDING = 2
const QUEUED = 3
const ACTIVE = 4
const EXECUTED = 5
const FAILED = 6
const EXPIRED = 7

const NAME = 8749144107276083488161720003882106979964465  # dolvenGovernanceV1 - felt - 0x646f6c76656e476f7665726e616e63655631 hex

@storage_var
func governanceStrategy() -> (res : felt):
end

@storage_var
func timeLocker() -> (res : felt):
end

@storage_var
func dolvenValidator() -> (res : felt):
end

@storage_var
func proposalNonce() -> (res : felt):
end

# #Structs
struct Proposal:
    member id : felt
    member creator : felt
    member proposalType : felt
    member startTimestamp : felt
    member endTimestamp : felt
    member executionTime : felt
    member forVotes : Uint256
    member againstVotes : Uint256
    member isExecuted : felt
    member isCancelled : felt
    member strategy : felt
    member ipfsHash : felt
end

struct Vote:
    member voteFrom : felt
    member voteProposalNonce : felt
    member voteResult : felt
    member votingPower : Uint256
end

# # Mappings

@storage_var
func proposals(nonce : felt) -> (res : Proposal):
end

@storage_var
func proposalCount(proposalId : felt) -> (voteIndexCount : felt):
end

@storage_var
func proposalsVotes(nonce : felt, voteIndex : felt) -> (res : Vote):
end

@storage_var
func userNonce(user_account : felt) -> (res : felt):
end

@storage_var
func userVotes(user_address : felt, voteIndex : felt) -> (res : Vote):
end

@storage_var
func userVotesForProposal(user_address : felt, proposalId : felt) -> (res : Vote):
end

# # Events

@event
func VoteEmitted(proposalId : felt, voter : felt, support : felt, votingPower : Uint256):
end

@event
func ProposalQueued(proposalId : felt, executionTime : felt, user : felt):
end

@event
func ProposalExecuted(proposalId : felt):
end

@event
func ProposalCancelled(proposalId : felt):
end

@event
func ProposalCreated(
    proposalId : felt,
    creator : felt,
    startTimestamp : felt,
    endTimestamp : felt,
    strategy : felt,
    ipfsHash : felt,
):
end

# # Constructor

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    governanceStrategy : felt,
    timeLocker : felt,
    validatorAddress : felt,
    firstSignerAddress : felt,
    secondSignerAddress : felt,
    initialApprover : felt,
):
    _setGovernanceStrategy(governanceStrategy)
    _setExecutor(timeLocker)
    _setDolvenValidator(validatorAddress)
    DolvenApprover(firstSignAddress, secondSignAddress, initialApprover)
    return ()
end

# # Viewers

@view
func returnGovernanceStrategy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    ) -> (strategyAddress : felt):
    let strategy : felt = governanceStrategy.read()
    return (strategy)
end

@view
func returnTimelocker{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    timeLocker : felt
):
    let executor : felt = timeLocker.read()
    return (executor)
end

@view
func returnValidator{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    validator : felt
):
    let validator : felt = dolvenValidator.read()
    return (validator)
end

@view
func returnproposalNonce{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    proposalNonce : felt
):
    let nonce : felt = proposalNonce.read()
    return (nonce)
end

@view
func returnProposalByNonce{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
    proposalDetails : Proposal
):
    let proposal : felt = proposals.read(proposalNonce)
    return (proposal)
end

@view
func returnVoteCountByProposal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    proposalId : felt
) -> (voteCount : felt):
    let proposalVoteCount : felt = proposalCount.read(proposalId)
    return (proposalVoteCount)
end

@view
func returnUserVoteCount{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_account : felt
) -> (voteCount : felt):
    let vote_count : felt = userNonce.read(user_account)
    return (vote_count)
end

@view
func returnUserVoteByProposal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    user_account : felt, proposal_id : felt
) -> (voteCount : felt):
    let vote_details : Vote = userVotesForProposal.read(user_account, proposal_id)
    return (vote_details)
end

# #recursive functions

# # External Functions

@external
func createProposal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    _ipfsHash : felt, _proposalType : felt
) -> (res : proposalId):
    let validor_address : felt = dolvenValidator.read()
    let (msg_sender) = get_caller_address()
    let timeLocker_address : felt = timeLocker.read()
    let (current_time) = get_block_timestamp()
    let governanceStrategy_address = governanceStrategy.read()
    let isProposalTypeValid : felt = IDolvenValidator.validateCreatorOfProposal(
        validor_address, proposalType
    )
    with_attr error_message("DolvenGovernance::createProposal PROPOSITION_CREATION_INVALID"):
        assert isProposalTypeValid = 1
    end
    let isCreatorValid : felt = IDolvenValidator.validateCreatorOfProposal(
        validor_address, msg_sender
    )
    with_attr error_message("DolvenGovernance::createProposal PROPOSITION_CREATION_INVALID"):
        assert isCreatorValid = 1
    end
    let VOTING_DELAY : felt = ITimelockController.getVotingDelay(timeLocker_address)
    let VOTING_DURATION : felt = ITimelockController.getVotingDuration(timeLocker_address)
    let proposalStartTime : felt = current_time + VOTING_DELAY
    let proposalEndTime : felt = current_time + VOTING_DURATION

    let nonce : felt = proposalNonce.read()
    let zero_as_uint256 : Uint256 = Uint256(0, 0)

    let new_proposal : Proposal = Proposal(
        id=nonce,
        creator=msg_sender,
        proposalType=_proposalType,
        startTimestamp=proposalStartTime,
        endTimestamp=proposalEndTime,
        executionTime=0,
        forVotes=zero_as_uint256,
        againstVotes=zero_as_uint256,
        isExecuted=FALSE,
        isCancelled=FALSE,
        strategy=governanceStrategy_address,
        ipfsHash=_ipfsHash,
    )
    proposals(nonce, new_proposal)

    ProposalCreated.emit(
        proposalId=nonce,
        creator=msg_sender,
        startTimestamp=proposalStartTime,
        endTimestamp=proposalEndTime,
        strategy=governanceStrategy_address,
        ipfsHash=_ipfsHash,
    )
    proposalNonce.write(nonce + 1)
    return (nonce)
end

@external
func cancelProposal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    _proposalId : felt
):
    DolvenApprover.onlyApprover()
    let state : felt = getProposalState(_proposalId)
    with_attr error_message("DolvenGovernance::cancelProposal ONLY_BEFORE_EXECUTED"):
        assert_not_equal(state, EXECUTED)
        assert_not_equal(state, CANCELLED)
        assert_not_equal(state, EXPIRED)
    end
    let proposalDetails : Proposal = proposals.read(_proposalId)

    let new_proposal : Proposal = Proposal(
        id=proposalDetails.id,
        creator=proposalDetails.creator,
        proposalType=proposalDetails.proposalType,
        startTimestamp=proposalDetails.startTimestamp,
        endTimestamp=proposalDetails.endTimestamp,
        executionTime=proposalDetails.executionTime,
        forVotes=proposalDetails.forVotes,
        againstVotes=proposalDetails.againstVotes,
        isExecuted=proposalDetails.isExecuted,
        isCancelled=TRUE,
        strategy=proposalDetails.strategy,
        ipfsHash=proposalDetails.ipfsHash,
    )
    proposals(proposalDetails.id, new_proposal)

    ProposalCancelled.emit(proposalId=proposalDetails.id)
    return ()
end

@external
func queueProposal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    _proposalId : felt
):
    DolvenApprover.onlyApprover()
    let state : felt = getProposalState(_proposalId)
    with_attr error_message("DolvenGovernance::queueProposal INVALID_STATE_FOR_QUEUE"):
        assert state = SUCCESS
    end
    let (msg_sender) = get_caller_address()
    let proposalDetails : Proposal = proposals.read(_proposalId)
    let (current_time) = get_block_timestamp()
    let _timeLocker : felt = timeLocker.read()
    let queueDelay : felt = ITimelockController.getDelay(_timeLocker)
    let _executionTime : felt = current_time + queueDelay
    let new_proposal : Proposal = Proposal(
        id=proposalDetails.id,
        creator=proposalDetails.creator,
        proposalType=proposalDetails.proposalType,
        startTimestamp=proposalDetails.startTimestamp,
        endTimestamp=proposalDetails.endTimestamp,
        executionTime=_executionTime,
        forVotes=proposalDetails.forVotes,
        againstVotes=proposalDetails.againstVotes,
        isExecuted=proposalDetails.isExecuted,
        isCancelled=proposalDetails.isCancelled,
        strategy=proposalDetails.strategy,
        ipfsHash=proposalDetails.ipfsHash,
    )
    proposals(proposalDetails.id, new_proposal)

    ProposalQueued.emit(
        proposalId=proposalDetails.id, executionTime=_executionTime, user=msg_sender
    )
    return ()
end

@external
func executeProposal{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    _proposalId : felt
):
    DolvenApprover.onlyApprover()
    let state : felt = getProposalState(_proposalId)
    with_attr error_message("DolvenGovernance::queueProposal ONLY_QUEUED_PROPOSALS"):
        assert state = QUEUED
    end
    let (msg_sender) = get_caller_address()
    let proposalDetails : Proposal = proposals.read(_proposalId)
    let new_proposal : Proposal = Proposal(
        id=proposalDetails.id,
        creator=proposalDetails.creator,
        proposalType=proposalDetails.proposalType,
        startTimestamp=proposalDetails.startTimestamp,
        endTimestamp=proposalDetails.endTimestamp,
        executionTime=_executionTime,
        forVotes=proposalDetails.forVotes,
        againstVotes=proposalDetails.againstVotes,
        isExecuted=TRUE,
        isCancelled=proposalDetails.isCancelled,
        strategy=proposalDetails.strategy,
        ipfsHash=proposalDetails.ipfsHash,
    )
    proposals(proposalDetails.id, new_proposal)

    ProposalExecuted.emit(proposalId=proposalDetails.id)
    return ()
end

@external
func submitVote(proposalId : felt, support : felt):
    let (msg_sender) = get_caller_address()
    _submitVote(msg_sender, proposalId, support)
    return ()
end

@external
func submitVoteBySignature(proposalId : felt, support : felt, sig : (felt, felt)):
    let (msg_sender) = get_caller_address()
    let (basic_hash) = hash2{hash_ptr=pedersen_ptr}(proposalId, support)
    let (basic_hash) = hash2{hash_ptr=pedersen_ptr}(basic_hash, NAME)

    # reverts, if cannot resolve the signature see: https://www.cairo-lang.org/docs/hello_starknet/signature_verification.html
    verify_ecdsa_signature(
        message=basic_hash, public_key=msg_sender, signature_r=sig[0], signature_s=sig[1]
    )

    _submitVote(msg_sender, proposalId, support)
    return ()
end

# # Setters

@external
func setGovernanceStrategy(strategy : felt):
    DolvenApprover.onlyApprover()
    _setGovernanceStrategy(strategy)
    return ()
end

@external
func setDolvenValidator(validator : felt):
    DolvenApprover.onlyApprover()
    _setDolvenValidator(validator)
    return ()
end

@external
func setDolvenExecutor(executor : felt):
    DolvenApprover.onlyApprover()
    _setExecutor(executor)
    return ()
end

# # Internal Functions

func _submitVote{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    voter : felt, proposalId : felt, support : felt
):
    let state : felt = getProposalState(proposalId)
    with_attr error_message("DolvenGovernance::_submitVote VOTING_CLOSED"):
        assert state = ACTIVE
    end
    let (msg_sender) = get_caller_address()
    let proposalDetails : Proposal = proposals.read(_proposalId)
    let user_vote : Vote = userVotesForProposal.read(msg_sender, _proposalId)
    let zero_as_uint256 : Uint256 = Uint256(0, 0)

    with_attr error_message("DolvenGovernance::_submitVote VOTE_ALREADY_SUBMITTED"):
        assert user_vote.votingPower = zero_as_uint256
    end
    let _forVotes : Uint256 = proposalDetails.forVotes
    let _againstVotes : Uint256 = proposalDetails.againstVotes
    let _votingPower : Uint256 = IDolvenVotingStrategy.getVotingPower(
        proposalDetails.strategy, msg_sender
    )
    if support == TRUE:
        let _forVotes : Uint256 = SafeUint256.add(_forVotes, _votingPower)
    else:
        let _againstVotes : Uint256 = SafeUint256.add(_againstVotes, _votingPower)
    end

    let user_nonce : felt = userNonce.read(msg_sender)
    let total_voteCount : felt = proposalCount.read(proposalId)

    let new_voteDetails : Vote = Vote(
        voteFrom=msg_sender,
        voteProposalNonce=proposalDetails.id,
        voteResult=support,
        votingPower=_votingPower,
    )

    let new_proposalDetails : Proposal = Proposal(
        id=proposalDetails.id,
        creator=proposalDetails.creator,
        proposalType=proposalDetails.proposalType,
        startTimestamp=proposalDetails.startTimestamp,
        endTimestamp=proposalDetails.endTimestamp,
        executionTime=proposalDetails.executionTime,
        forVotes=_forVotes,
        againstVotes=_againstVotes,
        isExecuted=proposalDetails.isExecuted,
        isCancelled=proposalDetails.isCancelled,
        strategy=proposalDetails.strategy,
        ipfsHash=proposalDetails.ipfsHash,
    )

    userVotes.write(msg_sender, user_nonce, new_voteDetails)
    userVotesForProposal.write(msg_sender, proposalDetails.id, new_voteDetails)
    proposalsVotes.write(proposalDetails.id, total_voteCount, new_voteDetails)
    proposalCount.write(total_voteCount + 1)
    user_nonce.write(user_nonce + 1)

    VoteEmitted.emit(
        proposalId=proposalDetails.id, voter=msg_sender, support=support, votingPower=_votingPower
    )
    return ()
end

func _setGovernanceStrategy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    strategy : felt
):
    governanceStrategy.write(strategy)
end

func _setDolvenValidator{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    validatorAddress : felt
):
    dolvenValidator.write(validatorAddress)
end

func _setExecutor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    executor : felt
):
    timeLocker.write(executor)
end
